import Foundation
import CoreFoundation

/// Foundation accepts duplicate JSON keys; linked config must have one interpretation before emitting a plist.
func decodeConfigJSON(_ data: Data) throws -> Any {
    guard data.count <= 256 * 1024 else { throw PlistError.invalidJSON("Config exceeds 256 KiB") }
    let parsed = try JSONSerialization.jsonObject(with: data)
    let bytes = Array(data)
    var index = 0
    func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    func stringToken() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let next = bytes[index]; index += 1
            if next == 92 { index += 1 }
            else if next == 34 {
                guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String else {
                    throw PlistError.invalidJSON("Invalid object key")
                }
                return value
            }
        }
        throw PlistError.invalidJSON("Unterminated string")
    }
    func scan(_ depth: Int) throws {
        guard depth <= 32 else { throw PlistError.invalidJSON("Config nesting exceeds 32 levels") }
        whitespace()
        switch bytes[index] {
        case 123:
            index += 1; whitespace()
            var keys: Set<String> = []
            if bytes[index] != 125 {
                while true {
                    whitespace()
                    guard keys.insert(try stringToken()).inserted else { throw PlistError.invalidJSON("Duplicate config field") }
                    whitespace(); index += 1; try scan(depth + 1); whitespace()
                    if bytes[index] != 44 { break }
                    index += 1
                }
            }
            index += 1
        case 91:
            index += 1; whitespace()
            if bytes[index] != 93 {
                while true {
                    try scan(depth + 1); whitespace()
                    if bytes[index] != 44 { break }
                    index += 1
                }
            }
            index += 1
        case 34: _ = try stringToken()
        default: while index < bytes.count && ![44, 93, 125, 9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
    }
    try scan(0)
    return parsed
}

func validateConfigPlistValue(_ value: Any, path: String) throws {
    if let object = value as? [String: Any] {
        for (key, value) in object { try validateConfigPlistValue(value, path: path + "." + key) }
    } else if let array = value as? [Any] {
        for value in array { try validateConfigPlistValue(value, path: path) }
    } else if value is String {
        return
    } else if let number = value as? NSNumber {
        guard CFGetTypeID(number) == CFBooleanGetTypeID() || (number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue &&
            number.doubleValue >= Double(Int64.min) && number.doubleValue < Double(Int64.max)) else { throw PlistError.invalidRequiredField(path) }
    } else { throw PlistError.invalidRequiredField(path) }
}

/// Uses the schema generated from the backend's records. This emitter has no
/// provider-specific field bag or secret-handling copy of the configuration.
func validateOAuthSnapshot(_ value: Any, platform: String, apiKey: String) throws {
    let document = try JSONSerialization.jsonObject(with: Data(oauthSchemaJSON.utf8)) as! [String: Any]
    let schemas = (document["components"] as! [String: Any])["schemas"] as! [String: Any]
    try validateOAuthValue(value, schema: schemas["SocialSnapshot"] as! [String: Any], schemas: schemas, path: "oauth")
    let oauth = value as! [String: Any]
    guard oauth["platform"] as? String == platform else { throw PlistError.invalidRequiredField("oauth.platform (different platform)") }
    let parts = apiKey.split(separator: "_", maxSplits: 2)
    guard parts.count == 3, parts[0] == "pb", oauth["environment_ref"] as? String == String(parts[1]) else { throw PlistError.invalidRequiredField("oauth.environment_ref (different environment from api_key)") }
    let clients = oauth["clients"] as! [[String: Any]]
    guard Set(clients.compactMap { $0["provider"] as? String }).count == clients.count,
          Set(clients.compactMap { $0["key"] as? String }).count == clients.count else { throw PlistError.invalidRequiredField("oauth.clients (duplicate provider or client key)") }
    for client in clients where client["mode"] as? String == "native" {
        guard client["bundle_id"] is String, client["package_name"] == nil else { throw PlistError.invalidRequiredField("oauth.clients (native client belongs to another platform)") }
    }
}

private func validateOAuthValue(_ value: Any, schema: [String: Any], schemas: [String: Any], path: String) throws {
    func invalid(_ field: String = "") -> PlistError { .invalidRequiredField(path+(field.isEmpty ? "" : "."+field)) }
    if value is NSNull { throw invalid() }
    if let ref = schema["$ref"] as? String {
        guard let name = ref.split(separator: "/").last, let target = schemas[String(name)] as? [String: Any] else { throw invalid() }
        try validateOAuthValue(value, schema: target, schemas: schemas, path: path); return
    }
    for union in ["oneOf", "anyOf"] {
        if let options = schema[union] as? [[String: Any]] {
            let matches = options.filter { (try? validateOAuthValue(value, schema: $0, schemas: schemas, path: path)) != nil }.count
            guard union == "oneOf" ? matches == 1 : matches > 0 else { throw invalid() }
        }
    }
    if let choices = schema["enum"] as? [NSObject], let object = value as? NSObject, !choices.contains(where: { $0.isEqual(object) }) { throw invalid() }
    switch schema["type"] as? String {
    case "object":
        guard let object = value as? [String: Any] else { throw invalid() }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for key in schema["required"] as? [String] ?? [] where object[key] == nil { throw invalid(key) }
        for (key, value) in object {
            if let property = properties[key] as? [String: Any] { try validateOAuthValue(value, schema: property, schemas: schemas, path: path+"."+key) }
            else if schema["additionalProperties"] as? Bool == false { throw invalid(key) }
        }
    case "array":
        guard let array = value as? [Any], let item = schema["items"] as? [String: Any] else { throw invalid() }
        if let min = schema["minItems"] as? Int, array.count < min { throw invalid() }
        if let max = schema["maxItems"] as? Int, array.count > max { throw invalid() }
        for (index, value) in array.enumerated() { try validateOAuthValue(value, schema: item, schemas: schemas, path: "\(path)[\(index)]") }
    case "string":
        guard let text = value as? String else { throw invalid() }
        if let min = schema["minLength"] as? Int, text.unicodeScalars.count < min { throw invalid() }
        if let max = schema["maxLength"] as? Int, text.unicodeScalars.count > max { throw invalid() }
        if let pattern = schema["pattern"] as? String {
            let expression = try NSRegularExpression(pattern: pattern)
            let whole = NSRange(text.startIndex..<text.endIndex, in: text)
            guard expression.firstMatch(in: text, range: whole)?.range == whole else { throw invalid() }
        }
        if schema["format"] as? String == "uri", URLComponents(string: text)?.scheme == nil { throw invalid() }
    case "integer", "number":
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw invalid() }
        if schema["type"] as? String == "integer", number.doubleValue.rounded() != number.doubleValue { throw invalid() }
    case "boolean":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid() }
    default: break
    }
}

func writeConfigValue(_ b: inout String, _ value: Any, _ indent: String) {
    switch value {
    case let object as [String: Any]:
        b += indent+"<dict>\n"
        for key in object.keys.sorted() {
            b += indent+"\t<key>"+configXML(key)+"</key>\n"
            writeConfigValue(&b, object[key]!, indent+"\t")
        }
        b += indent+"</dict>\n"
    case let values as [Any]:
        b += indent+"<array>\n"; for value in values { writeConfigValue(&b,value,indent+"\t") }; b += indent+"</array>\n"
    case let text as String: b += indent+"<string>"+configXML(text)+"</string>\n"
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { b += indent+(number.boolValue ? "<true/>\n" : "<false/>\n") }
        else { b += indent+"<integer>\(number.int64Value)</integer>\n" }
    default: preconditionFailure("Validated config contains a non-plist value")
    }
}
private func configXML(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
