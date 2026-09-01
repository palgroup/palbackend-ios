import Foundation

// Parse.swift — OpenAPI 3.1 → intermediate AST. Port of swiftgen.go.
// Coder-parse fills this in (Phase 1, T1.1).

// --- AST (mirror of swiftgen.go's swiftSchema/swiftProp/swiftOp/...) ----------

struct SwiftSchema {
    var kind: String            // string|number|integer|boolean|object|array|enum|any
    var nullable: Bool
    var props: [SwiftProp]      // object
    var elem: Box<SwiftSchema>? // array element (Box breaks the recursive value cycle)
    var enumVals: [String]      // enum
}

struct SwiftProp {
    var name: String
    var schema: SwiftSchema
    var required: Bool
}

struct SwiftUpload {
    var bucket: String
    var pathTemplate: String
}

struct SwiftErrorDef {
    var name: String          // lowerCamel case identifier (e.g. "todoLocked")
    var code: String          // wire `error` value (e.g. "todo_locked")
    var status: Int
    var description: String
    var data: SwiftSchema?    // nil when the error carries no payload
}

/// One `@Room` declaration, read from the document-level `x-palbase-room`.
///
/// Rooms are the one thing in the spec that is NOT an operation: no verb, no
/// path, no request/response pair. They are server code a device talks to over
/// the realtime socket, so the generator emits a typed handle instead of an
/// endpoint.
struct SwiftRoom {
    /// The channel pattern, colon-separated: `ai:{sessionId}`.
    var pattern: String
    /// The `{param}` names, in the order they appear in the pattern. They become
    /// stored properties so the app never interpolates a topic by hand.
    var params: [String]
    /// Events the SERVER sends, by name.
    var events: [SwiftRoomPayload]
    /// Messages a CLIENT may send, by name.
    var messages: [SwiftRoomPayload]
}

struct SwiftRoomPayload {
    var name: String
    var schema: SwiftSchema
}

struct SwiftOp {
    var operationID: String
    var method: String
    var path: String
    var pathParams: [String]
    var input: SwiftSchema?
    var output: SwiftSchema?
    var headers: SwiftSchema?
    var query: SwiftSchema?
    var errors: [SwiftErrorDef]
    var upload: SwiftUpload?
    /// True when the operation carries `x-palbase-sse` — a streaming response
    /// whose body is a sequence of frames, not one JSON document. Defaulted so
    /// every existing construction site keeps compiling and keeps meaning
    /// "ordinary op".
    var sse: Bool = false
}

// Box wraps a value type to allow recursion (Swift structs can't contain
// themselves by value). Used for SwiftSchema.elem.
final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

enum CodegenError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case missingPaths
    var description: String {
        switch self {
        case .invalidJSON(let m): return "openapi.json is not valid JSON: \(m)"
        case .missingPaths: return "openapi.json has no `paths`"
        }
    }
}

// intFromDouble truncates toward zero like Go's `int(float64)` WITHOUT trapping.
// `Int(d)` aborts the process for NaN / ±inf / out-of-Int-range doubles; the Go
// generator we ported clamps instead, so a malformed `status` (e.g. 1e20) must
// not crash a consumer's Xcode build. NaN → 0; out-of-range → Int bounds.
func intFromDouble(_ d: Double) -> Int {
    if d.isNaN { return 0 }
    if d >= Double(Int.max) { return Int.max }
    if d <= Double(Int.min) { return Int.min }
    return Int(d)
}

// parseOpenAPIForSwift parses the spec bytes into a sorted [SwiftOp].
// Byte-for-byte port of swiftgen.go's parseOpenAPIForSwift.
func parseOpenAPIForSwift(_ specBytes: Data) throws -> [SwiftOp] {
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: specBytes)
    } catch {
        throw CodegenError.invalidJSON(error.localizedDescription)
    }
    guard let root = parsed as? [String: Any] else {
        throw CodegenError.invalidJSON("root is not an object")
    }
    guard let paths = root["paths"] as? [String: Any] else {
        throw CodegenError.missingPaths
    }

    var ops: [SwiftOp] = []
    for (path, item) in paths {
        guard let methods = item as? [String: Any] else {
            continue
        }
        for (method, raw) in methods {
            guard let op = raw as? [String: Any] else {
                continue
            }
            let opID = (op["operationId"] as? String) ?? ""
            if opID == "" {
                continue
            }
            ops.append(SwiftOp(
                operationID: opID,
                method: method.uppercased(),
                path: path,
                pathParams: pathParamNames(path),
                input: requestSchema(op),
                output: responseSchema(op),
                headers: headerSchema(op),
                query: querySchema(op),
                errors: declaredErrors(op),
                upload: declaredUpload(op),
                sse: declaredSse(op)
            ))
        }
    }
    ops.sort { $0.operationID < $1.operationID }
    return ops
}

// declaredErrors reads the `x-palbase-errors` OpenAPI extension. Returns []
// (Go's nil) when no errors were inferred. Sorted by case name.
private func declaredErrors(_ op: [String: Any]) -> [SwiftErrorDef] {
    guard let extRaw = op["x-palbase-errors"] as? [String: Any], !extRaw.isEmpty else {
        return []
    }
    let responses = op["responses"] as? [String: Any]
    var out: [SwiftErrorDef] = []
    out.reserveCapacity(extRaw.count)
    for (name, raw) in extRaw {
        guard let entry = raw as? [String: Any] else {
            continue
        }
        let statusF = (entry["status"] as? NSNumber)?.doubleValue ?? 0
        let code = (entry["code"] as? String) ?? ""
        let description = (entry["description"] as? String) ?? ""
        let hasData = (entry["hasData"] as? Bool) ?? false
        if code == "" || statusF == 0 {
            continue
        }
        // Truncate toward zero like Go's `int(float64)`. Plain `Int(statusF)`
        // TRAPS for out-of-range doubles (1e20, NaN) — Go clamps instead of
        // panicking, so a garbage `status` must not abort the build. Match Go.
        let status = intFromDouble(statusF)
        var def = SwiftErrorDef(
            name: name,
            code: code,
            status: status,
            description: description,
            data: nil
        )
        if hasData {
            def.data = errorDataSchema(responses, status, code)
        }
        out.append(def)
    }
    // Deterministic order: by case name.
    out.sort { $0.name < $1.name }
    return out
}

// declaredUpload reads the `x-palbase-upload` OpenAPI extension. nil for a
// normal op. bucket + pathTemplate are required.
private func declaredUpload(_ op: [String: Any]) -> SwiftUpload? {
    guard let ext = op["x-palbase-upload"] as? [String: Any], !ext.isEmpty else {
        return nil
    }
    let bucket = (ext["bucket"] as? String) ?? ""
    let pathTemplate = (ext["pathTemplate"] as? String) ?? ""
    if bucket == "" || pathTemplate == "" {
        // Malformed extension — treat as a non-upload op.
        return nil
    }
    return SwiftUpload(bucket: bucket, pathTemplate: pathTemplate)
}

// declaredSse reports whether the operation carries `x-palbase-sse`.
//
// The extension's PRESENCE is the whole signal — it carries no fields today, by
// design, so that a later setting arrives as a field on a marker every consumer
// already reads rather than as a second marker some consumer misses. A document
// without it describes a streaming route as a plain POST, and the client
// generated from that reads the body once instead of iterating frames: it
// compiles, it runs, and it is simply wrong.
private func declaredSse(_ op: [String: Any]) -> Bool {
    return op["x-palbase-sse"] != nil
}

// errorDataSchema pulls the data-payload schema out of a declared error's
// response shape. oneOf → pick the variant whose `error.const` matches code.
private func errorDataSchema(_ responses: [String: Any]?, _ status: Int, _ code: String) -> SwiftSchema? {
    guard let responses = responses else {
        return nil
    }
    guard let resp = responses[String(status)] as? [String: Any] else {
        return nil
    }
    guard let content = resp["content"] as? [String: Any] else {
        return nil
    }
    guard let jsonCT = content["application/json"] as? [String: Any] else {
        return nil
    }
    guard let schema = jsonCT["schema"] as? [String: Any] else {
        return nil
    }

    // oneOf: pick the variant whose `error.const` matches our code.
    if let variants = schema["oneOf"] as? [Any] {
        for v in variants {
            guard let vm = v as? [String: Any] else {
                continue
            }
            let props = vm["properties"] as? [String: Any]
            if let errProp = props?["error"] as? [String: Any] {
                if let c = errProp["const"] as? String, c == code {
                    return extractDataProperty(vm)
                }
            }
        }
        return nil
    }
    return extractDataProperty(schema)
}

private func extractDataProperty(_ schema: [String: Any]) -> SwiftSchema? {
    guard let props = schema["properties"] as? [String: Any] else {
        return nil
    }
    guard let dm = props["data"] as? [String: Any] else {
        return nil
    }
    return parseSwiftSchema(dm)
}

private func requestSchema(_ op: [String: Any]) -> SwiftSchema? {
    guard let body = op["requestBody"] as? [String: Any] else {
        return nil
    }
    return schemaFromContent(body["content"])
}

private func headerSchema(_ op: [String: Any]) -> SwiftSchema? {
    return parametersSchemaIn(op, "header")
}

private func querySchema(_ op: [String: Any]) -> SwiftSchema? {
    return parametersSchemaIn(op, "query")
}

// parametersSchemaIn collects the operation's `parameters[in:<where>]` entries
// into a synthetic object swiftSchema, name-sorted. nil when none.
private func parametersSchemaIn(_ op: [String: Any], _ where_: String) -> SwiftSchema? {
    guard let paramsRaw = op["parameters"] as? [Any], !paramsRaw.isEmpty else {
        return nil
    }
    var props: [SwiftProp] = []
    for p in paramsRaw {
        guard let pm = p as? [String: Any] else {
            continue
        }
        // Go: `if in, _ := pm["in"].(string); in != where { continue }`.
        // Missing/non-string `in` yields "" which != where → skip.
        let inLoc = (pm["in"] as? String) ?? ""
        if inLoc != where_ {
            continue
        }
        let name = (pm["name"] as? String) ?? ""
        if name == "" {
            continue
        }
        let required = (pm["required"] as? Bool) ?? false
        let ps: SwiftSchema
        if let sm = pm["schema"] as? [String: Any] {
            ps = parseSwiftSchema(sm)
        } else {
            ps = SwiftSchema(kind: "string", nullable: false, props: [], elem: nil, enumVals: [])
        }
        props.append(SwiftProp(name: name, schema: ps, required: required))
    }
    if props.isEmpty {
        return nil
    }
    // Deterministic field order.
    props.sort { $0.name < $1.name }
    return SwiftSchema(kind: "object", nullable: false, props: props, elem: nil, enumVals: [])
}

// pathParamNames extracts `{name}` template segments in left-to-right order.
// Empty `{}` is ignored. Returns [] when no templated segments.
private func pathParamNames(_ path: String) -> [String] {
    var out: [String] = []
    var rest = Array(path.utf8)
    while true {
        guard let open = rest.firstIndex(of: UInt8(ascii: "{")) else {
            break
        }
        // Go: close := IndexByte(path[open:], '}'); if < 0 break; close += open.
        // firstIndex over rest[open...] already returns an absolute index.
        guard let close = rest[open...].firstIndex(of: UInt8(ascii: "}")) else {
            break
        }
        let name = String(decoding: rest[(open + 1)..<close], as: UTF8.self)
        if name != "" {
            out.append(name)
        }
        rest = Array(rest[(close + 1)...])
    }
    return out
}

private func responseSchema(_ op: [String: Any]) -> SwiftSchema? {
    guard let responses = op["responses"] as? [String: Any] else {
        return nil
    }
    // Prefer 200, then 201, then any other 2xx (sorted).
    var order = ["200", "201"]
    var others: [String] = []
    for code in responses.keys {
        if code.hasPrefix("2") && code != "200" && code != "201" {
            others.append(code)
        }
    }
    others.sort()
    order.append(contentsOf: others)
    for code in order {
        guard let resp = responses[code] as? [String: Any] else {
            continue
        }
        if let s = schemaFromContent(resp["content"]) {
            return s
        }
    }
    return nil
}

private func schemaFromContent(_ content: Any?) -> SwiftSchema? {
    guard let c = content as? [String: Any] else {
        return nil
    }
    guard let jsonCt = c["application/json"] as? [String: Any] else {
        return nil
    }
    guard let schema = jsonCt["schema"] as? [String: Any] else {
        return nil
    }
    // Skip $ref'd shared components (error envelope etc.).
    if schema["$ref"] != nil {
        return nil
    }
    return parseSwiftSchema(schema, root: schema)
}

private func parseSwiftSchema(_ s: [String: Any]) -> SwiftSchema {
    parseSwiftSchema(s, root: s)
}

// `root` is the schema the walk started from: zod emits a repeated subschema
// once and points at it with a document-relative `$ref` ("#/properties/
// selectedContext"), so resolving one means walking that JSON Pointer from the
// enclosing schema. `depth` stops a self-referential spec from recursing
// forever — a ref chain that deep is a spec bug, and `any` is the honest answer.
private func parseSwiftSchema(_ s0: [String: Any], root: [String: Any], depth: Int = 0) -> SwiftSchema {
    var s = s0
    if let target = resolveSchemaRef(s, root: root), depth < 16 {
        s = target
    } else if s["$ref"] != nil {
        return SwiftSchema(kind: "any", nullable: false, props: [], elem: nil, enumVals: [])
    }
    var nullable = (s["nullable"] as? Bool) ?? false

    // `type: [<something>, "null"]` MEANS NULLABLE, AND IT IS READ HERE — BEFORE
    // the enum branch below.
    //
    // It used to be read only in the scalar `switch` at the bottom, which the
    // enum branch returns before ever reaching. So a nullable ENUM
    // (`{"type":["string","null"], "enum":[…]}` — what `z.enum(…).nullable()`
    // emits) came out NON-optional, and a null in the response could not decode
    // at all. Measured 2026-08-24 against centauri: `rejectionReason` on a
    // verification that was never rejected is null on the wire, and the emitted
    // client declared it required — the screen could not be typed, let alone
    // decoded.
    if let typeArray = s["type"] as? [Any] {
        for v in typeArray where (v as? String) == "null" {
            nullable = true
        }
    }

    // `anyOf: [<schema>, {"type":"null"}]` is what zod's `.nullable()` emits for
    // everything that isn't a scalar (objects, arrays, enums) — the scalar case
    // arrives as `type: ["string","null"]` and is handled below. Collapse the
    // pair into "that schema, nullable" instead of degrading the whole field to
    // `AnyCodableValue`: a nullable array-of-objects (a Home feed module's
    // `cards`) must stay typed, or every consumer hand-writes the DTO the
    // generator was supposed to give them.
    if let variants = (s["anyOf"] as? [Any]) ?? (s["oneOf"] as? [Any]) {
        let objects = variants.compactMap { $0 as? [String: Any] }
        let nonNull = objects.filter { !isNullSchema($0) }
        if objects.count == variants.count, nonNull.count == 1, objects.count > nonNull.count {
            var inner = parseSwiftSchema(nonNull[0], root: root, depth: depth + 1)
            inner.nullable = true
            return inner
        }
    }

    if let enumRaw = s["enum"] as? [Any] {
        var cases: [String] = []
        var allStrings = true
        for v in enumRaw {
            if let str = v as? String {
                cases.append(str)
            } else {
                allStrings = false
                break
            }
        }
        if allStrings && !cases.isEmpty {
            return SwiftSchema(kind: "enum", nullable: nullable, props: [], elem: nil, enumVals: cases)
        }
    }

    // type may be a string or an array (`["string","null"]`). The null marker is
    // already folded into `nullable` above; this loop is here for `typ`.
    var typ = (s["type"] as? String) ?? ""
    if typ == "" {
        if let arr = s["type"] as? [Any] {
            for v in arr {
                if let str = v as? String {
                    if str == "null" {
                        nullable = true
                    } else if typ == "" {
                        typ = str
                    }
                }
            }
        }
    }
    switch typ {
    case "string":
        return SwiftSchema(kind: "string", nullable: nullable, props: [], elem: nil, enumVals: [])
    case "number":
        return SwiftSchema(kind: "number", nullable: nullable, props: [], elem: nil, enumVals: [])
    case "integer":
        return SwiftSchema(kind: "integer", nullable: nullable, props: [], elem: nil, enumVals: [])
    case "boolean":
        return SwiftSchema(kind: "boolean", nullable: nullable, props: [], elem: nil, enumVals: [])
    case "array":
        let elem: SwiftSchema
        if let items = s["items"] as? [String: Any] {
            elem = parseSwiftSchema(items, root: root, depth: depth + 1)
        } else {
            elem = SwiftSchema(kind: "any", nullable: false, props: [], elem: nil, enumVals: [])
        }
        return SwiftSchema(kind: "array", nullable: nullable, props: [], elem: Box(elem), enumVals: [])
    case "object":
        return parseSwiftObject(s, nullable, root: root, depth: depth)
    default:
        if s["properties"] != nil {
            return parseSwiftObject(s, nullable, root: root, depth: depth)
        }
        return SwiftSchema(kind: "any", nullable: nullable, props: [], elem: nil, enumVals: [])
    }
}

private func parseSwiftObject(_ s: [String: Any], _ nullable: Bool, root: [String: Any], depth: Int) -> SwiftSchema {
    let propsRaw = (s["properties"] as? [String: Any]) ?? [:]
    var requiredSet = Set<String>()
    if let reqRaw = s["required"] as? [Any] {
        for r in reqRaw {
            if let str = r as? String {
                requiredSet.insert(str)
            }
        }
    }
    var names: [String] = []
    for name in propsRaw.keys {
        names.append(name)
    }
    names.sort()
    var props: [SwiftProp] = []
    for name in names {
        let ps: SwiftSchema
        if let pm = propsRaw[name] as? [String: Any] {
            ps = parseSwiftSchema(pm, root: root, depth: depth + 1)
        } else {
            ps = SwiftSchema(kind: "any", nullable: false, props: [], elem: nil, enumVals: [])
        }
        props.append(SwiftProp(name: name, schema: ps, required: requiredSet.contains(name)))
    }
    return SwiftSchema(kind: "object", nullable: nullable, props: props, elem: nil, enumVals: [])
}

/// True for the `{"type":"null"}` variant zod emits inside `anyOf` for a
/// `.nullable()` object/array/enum.
private func isNullSchema(_ s: [String: Any]) -> Bool {
    if let t = s["type"] as? String { return t == "null" }
    if let t = s["type"] as? [Any] {
        let strs = t.compactMap { $0 as? String }
        return strs == ["null"]
    }
    return false
}

/// Resolve a document-relative `$ref` ("#/properties/selectedContext") against
/// the schema the walk started from. Returns nil when there is no `$ref`, when
/// the pointer is external (another file / `#/components/...` the CLI does not
/// carry), or when it does not land on an object.
private func resolveSchemaRef(_ s: [String: Any], root: [String: Any]) -> [String: Any]? {
    guard let ref = s["$ref"] as? String, ref.hasPrefix("#/") else { return nil }
    var node: Any = root
    for rawPart in ref.dropFirst(2).split(separator: "/") {
        let part = String(rawPart)
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
        if let dict = node as? [String: Any], let next = dict[part] {
            node = next
        } else if let arr = node as? [Any], let i = Int(part), arr.indices.contains(i) {
            node = arr[i]
        } else {
            return nil
        }
    }
    return node as? [String: Any]
}

// MARK: - rooms

/// parseRoomsForSwift reads the DOCUMENT-level `x-palbase-room` extension.
///
/// Document-level and not operation-level, and that is not a detail: a room has
/// no verb and no path to hang an extension off. A generator that looks for it
/// beside `x-palbase-sse` finds nothing, emits nothing, and reports success —
/// which is why the placement is pinned by a test.
///
/// A malformed entry is SKIPPED rather than thrown on, matching how
/// `declaredUpload` treats a half-written extension: a spec this generator
/// cannot fully read must still produce a working client for the parts it can.
func parseRoomsForSwift(_ specBytes: Data) throws -> [SwiftRoom] {
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: specBytes)
    } catch {
        throw CodegenError.invalidJSON(error.localizedDescription)
    }
    guard let root = parsed as? [String: Any] else {
        throw CodegenError.invalidJSON("root is not an object")
    }
    guard let ext = root["x-palbase-room"] as? [String: Any] else {
        return [] // a project with no rooms — the common case, and not an error
    }

    var out: [SwiftRoom] = []
    for (pattern, raw) in ext {
        guard let decl = raw as? [String: Any] else { continue }
        let events = roomPayloads(decl["events"], root: root)
        let messages = roomPayloads(decl["messages"], root: root)
        out.append(SwiftRoom(
            pattern: pattern,
            params: roomParamNames(pattern),
            events: events,
            messages: messages
        ))
    }
    // Deterministic order: a generator whose output depends on dictionary
    // iteration produces a different file on every run and no golden can hold it.
    out.sort { $0.pattern < $1.pattern }
    return out
}

/// The `{param}` names in a colon-separated pattern, in order.
private func roomParamNames(_ pattern: String) -> [String] {
    var names: [String] = []
    for seg in pattern.split(separator: ":", omittingEmptySubsequences: false) {
        let s = String(seg)
        guard s.hasPrefix("{"), s.hasSuffix("}"), s.count > 2 else { continue }
        names.append(String(s.dropFirst().dropLast()))
    }
    return names
}

/// Resolve each `{name: {$ref}}` entry into a named schema.
///
/// The refs point at `#/components/schemas/Room_<slug>_<name>` — registered by
/// the backend SDK precisely so the payload travels as a real component instead
/// of being inlined twice.
private func roomPayloads(_ raw: Any?, root: [String: Any]) -> [SwiftRoomPayload] {
    guard let map = raw as? [String: Any] else { return [] }
    var out: [SwiftRoomPayload] = []
    for (name, entry) in map {
        guard let dict = entry as? [String: Any] else { continue }
        // Resolve against the ROOT document: unlike an operation's inline schema,
        // a room's payload always lives in components.
        let target = resolveRoomRef(dict, root: root) ?? dict
        out.append(SwiftRoomPayload(name: name, schema: parseSwiftSchema(target, root: target)))
    }
    out.sort { $0.name < $1.name }
    return out
}

private func resolveRoomRef(_ s: [String: Any], root: [String: Any]) -> [String: Any]? {
    guard let ref = s["$ref"] as? String, ref.hasPrefix("#/") else { return nil }
    var node: Any = root
    for rawPart in ref.dropFirst(2).split(separator: "/") {
        let part = String(rawPart)
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
        guard let dict = node as? [String: Any], let next = dict[part] else { return nil }
        node = next
    }
    return node as? [String: Any]
}
