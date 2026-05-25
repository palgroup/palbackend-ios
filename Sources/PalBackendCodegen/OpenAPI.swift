import Foundation

// Minimal OpenAPI 3.1 model — only the parts palbackend's runtime emits.
// Input/output schemas are inlined per-operation (no $refs except the shared
// error envelope, which we ignore — errors are handled by BackendError).

/// A JSON Schema node as it appears inline in the spec.
struct SchemaNode {
    indirect enum Kind {
        case string
        case number       // JSON "number"
        case integer
        case boolean
        case object(properties: [(name: String, schema: SchemaNode, required: Bool)])
        case array(element: SchemaNode)
        case stringEnum(cases: [String])
        case any          // unknown / empty schema → AnyCodable fallback
    }
    var kind: Kind
    var nullable: Bool

    init(kind: Kind, nullable: Bool = false) {
        self.kind = kind
        self.nullable = nullable
    }
}

/// One backend operation: `rooms.create` → POST /rpc/rooms.create.
struct Operation {
    let operationId: String          // dotted, e.g. "rooms.id.get"
    let input: SchemaNode?           // requestBody schema (object), nil if none
    let output: SchemaNode?          // 200 response schema, nil if none/void
}

enum OpenAPIParseError: Error, CustomStringConvertible {
    case notJSON(String)
    case noPaths

    var description: String {
        switch self {
        case .notJSON(let m): return "openapi.json is not valid JSON: \(m)"
        case .noPaths: return "openapi.json has no `paths`"
        }
    }
}

enum OpenAPIParser {
    /// Parse the spec bytes into a sorted list of operations.
    static func parse(_ data: Data) throws -> [Operation] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenAPIParseError.notJSON(error.localizedDescription)
        }
        guard let obj = root as? [String: Any],
              let paths = obj["paths"] as? [String: Any] else {
            throw OpenAPIParseError.noPaths
        }

        var ops: [Operation] = []
        for (_, item) in paths {
            guard let methods = item as? [String: Any] else { continue }
            // Wire convention: every endpoint is POST /rpc/{op}. Read the
            // POST operation; tolerate other verbs by scanning all.
            for (_, raw) in methods {
                guard let op = raw as? [String: Any],
                      let opId = op["operationId"] as? String, !opId.isEmpty else { continue }
                ops.append(Operation(
                    operationId: opId,
                    input: requestSchema(op),
                    output: responseSchema(op)
                ))
            }
        }
        // Deterministic order for stable golden output.
        ops.sort { $0.operationId < $1.operationId }
        return ops
    }

    private static func requestSchema(_ op: [String: Any]) -> SchemaNode? {
        guard let body = op["requestBody"] as? [String: Any],
              let content = body["content"] as? [String: Any],
              let json = content["application/json"] as? [String: Any],
              let schema = json["schema"] as? [String: Any] else { return nil }
        return parseSchema(schema)
    }

    private static func responseSchema(_ op: [String: Any]) -> SchemaNode? {
        guard let responses = op["responses"] as? [String: Any] else { return nil }
        // Prefer 200, then 201, then any 2xx.
        let candidates = ["200", "201"] + responses.keys.filter { $0.hasPrefix("2") }.sorted()
        for code in candidates {
            guard let resp = responses[code] as? [String: Any],
                  let content = resp["content"] as? [String: Any],
                  let json = content["application/json"] as? [String: Any],
                  let schema = json["schema"] as? [String: Any] else { continue }
            // Skip $ref'd error envelopes etc.
            if schema["$ref"] != nil { continue }
            return parseSchema(schema)
        }
        return nil
    }

    /// Convert one inline JSON Schema object into a SchemaNode.
    static func parseSchema(_ s: [String: Any]) -> SchemaNode {
        let nullable = (s["nullable"] as? Bool) ?? false

        if let enumVals = s["enum"] as? [Any] {
            let cases = enumVals.compactMap { $0 as? String }
            if cases.count == enumVals.count, !cases.isEmpty {
                return SchemaNode(kind: .stringEnum(cases: cases), nullable: nullable)
            }
        }

        let type = s["type"] as? String
        switch type {
        case "string":
            return SchemaNode(kind: .string, nullable: nullable)
        case "number":
            return SchemaNode(kind: .number, nullable: nullable)
        case "integer":
            return SchemaNode(kind: .integer, nullable: nullable)
        case "boolean":
            return SchemaNode(kind: .boolean, nullable: nullable)
        case "array":
            let items = (s["items"] as? [String: Any]).map(parseSchema) ?? SchemaNode(kind: .any)
            return SchemaNode(kind: .array(element: items), nullable: nullable)
        case "object":
            return SchemaNode(kind: parseObject(s), nullable: nullable)
        default:
            // No explicit type but has properties → treat as object.
            if s["properties"] != nil { return SchemaNode(kind: parseObject(s), nullable: nullable) }
            return SchemaNode(kind: .any, nullable: nullable)
        }
    }

    private static func parseObject(_ s: [String: Any]) -> SchemaNode.Kind {
        let props = (s["properties"] as? [String: Any]) ?? [:]
        let required = Set((s["required"] as? [Any])?.compactMap { $0 as? String } ?? [])
        // Sort property names for deterministic output.
        let fields = props.keys.sorted().map { name -> (String, SchemaNode, Bool) in
            let schema = (props[name] as? [String: Any]).map(parseSchema) ?? SchemaNode(kind: .any)
            return (name, schema, required.contains(name))
        }
        return .object(properties: fields.map { (name: $0.0, schema: $0.1, required: $0.2) })
    }
}
