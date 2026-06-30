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
                upload: declaredUpload(op)
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
        var def = SwiftErrorDef(
            name: name,
            code: code,
            status: Int(statusF),
            description: description,
            data: nil
        )
        if hasData {
            def.data = errorDataSchema(responses, Int(statusF), code)
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
    return parseSwiftSchema(schema)
}

private func parseSwiftSchema(_ s: [String: Any]) -> SwiftSchema {
    var nullable = (s["nullable"] as? Bool) ?? false

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

    // type may be a string or an array (`["string","null"]`).
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
            elem = parseSwiftSchema(items)
        } else {
            elem = SwiftSchema(kind: "any", nullable: false, props: [], elem: nil, enumVals: [])
        }
        return SwiftSchema(kind: "array", nullable: nullable, props: [], elem: Box(elem), enumVals: [])
    case "object":
        return parseSwiftObject(s, nullable)
    default:
        if s["properties"] != nil {
            return parseSwiftObject(s, nullable)
        }
        return SwiftSchema(kind: "any", nullable: nullable, props: [], elem: nil, enumVals: [])
    }
}

private func parseSwiftObject(_ s: [String: Any], _ nullable: Bool) -> SwiftSchema {
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
            ps = parseSwiftSchema(pm)
        } else {
            ps = SwiftSchema(kind: "any", nullable: false, props: [], elem: nil, enumVals: [])
        }
        props.append(SwiftProp(name: name, schema: ps, required: requiredSet.contains(name)))
    }
    return SwiftSchema(kind: "object", nullable: nullable, props: props, elem: nil, enumVals: [])
}
