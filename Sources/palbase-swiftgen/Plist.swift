import Foundation

// Plist.swift — emits Palbase-Info.plist from the fixed platform config slots
// written by `palbase ios link` and `palbase macos link`:
//
//   { app_id, env_preset, base_url, api_key,
//     oauth?: { apple?: {enabled}, google?: {enabled, client_id, redirect_uri} } }
//
// Output is an `{ios?, macos?}` envelope whose values are platform config dicts. A
// single available platform is valid; absent platforms stay absent. The format
// uses fixed key order, indentation, and DOCTYPE.

enum PlistError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case noEnvironments
    case invalidRequiredField(String)
    var description: String {
        switch self {
        case .invalidJSON(let m): return "palbase-config.json is not valid JSON: \(m)"
        case .noEnvironments: return "refusing to write plist: no registered environments to emit"
        case .invalidRequiredField(let field):
            return "palbase-config.json is missing nonempty required field \(field)"
        }
    }
}

// Platform-envelope emitter. Each argument is the JSON from its matching
// fixed slot. Missing one platform never borrows the other platform's config.
func emitPlist(iosConfigBytes: Data?, macOSConfigBytes: Data?) throws -> String {
    guard iosConfigBytes != nil || macOSConfigBytes != nil else {
        throw PlistError.noEnvironments
    }

    let ios = try iosConfigBytes.map(decodeConfig)
    let macOS = try macOSConfigBytes.map(decodeConfig)

    var b = plistHeader
    b += "<dict>\n"
    if let ios {
        b += "\t<key>ios</key>\n"
        writeConfigDict(&b, ios, "\t")
    }
    if let macOS {
        b += "\t<key>macos</key>\n"
        writeConfigDict(&b, macOS, "\t")
    }
    b += "</dict>\n"
    b += "</plist>\n"
    return b
}

private let plistHeader = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">

"""

private func decodeConfig(_ configBytes: Data) throws -> [String: Any] {
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: configBytes)
    } catch {
        throw PlistError.invalidJSON(error.localizedDescription)
    }
    guard let env = root as? [String: Any], !env.isEmpty else {
        throw PlistError.noEnvironments
    }
    for field in ["app_id", "base_url", "api_key"] {
        guard let value = env[field] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlistError.invalidRequiredField(field)
        }
    }
    return env
}

private func writeConfigDict(_ b: inout String, _ env: [String: Any], _ indent: String) {
    b += indent + "<dict>\n"
    // Fixed key order for every platform slot.
    let fields: [(String, String)] = [
        ("app_id", str(env, "app_id")),
        ("env_preset", str(env, "env_preset")),
        ("base_url", str(env, "base_url")),
        ("api_key", str(env, "api_key")),
    ]
    for (key, val) in fields {
        b += indent + "\t<key>" + plistEscape(key) + "</key>\n"
        b += indent + "\t<string>" + plistEscape(val) + "</string>\n"
    }
    writeOAuthDict(&b, env["oauth"] as? [String: Any], indent + "\t")
    b += indent + "</dict>\n"
}

private func writeOAuthDict(_ b: inout String, _ oauth: [String: Any]?, _ indent: String) {
    guard let oauth else { return }
    let apple = oauth["apple"] as? [String: Any]
    let google = oauth["google"] as? [String: Any]
    if apple == nil && google == nil { return }

    b += indent + "<key>oauth</key>\n"
    b += indent + "<dict>\n"
    if let apple {
        b += indent + "\t<key>apple</key>\n"
        b += indent + "\t<dict>\n"
        b += indent + "\t\t<key>enabled</key>\n"
        b += indent + "\t\t" + plistBool(bool(apple, "enabled")) + "\n"
        b += indent + "\t</dict>\n"
    }
    if let google {
        b += indent + "\t<key>google</key>\n"
        b += indent + "\t<dict>\n"
        b += indent + "\t\t<key>enabled</key>\n"
        b += indent + "\t\t" + plistBool(bool(google, "enabled")) + "\n"
        for (key, val) in [("client_id", str(google, "client_id")), ("redirect_uri", str(google, "redirect_uri"))] {
            b += indent + "\t\t<key>" + plistEscape(key) + "</key>\n"
            b += indent + "\t\t<string>" + plistEscape(val) + "</string>\n"
        }
        b += indent + "\t</dict>\n"
    }
    b += indent + "</dict>\n"
}

private func str(_ m: [String: Any], _ k: String) -> String { (m[k] as? String) ?? "" }
private func bool(_ m: [String: Any], _ k: String) -> Bool { (m[k] as? Bool) ?? false }

private func plistBool(_ v: Bool) -> String { v ? "<true/>" : "<false/>" }

// plistEscape mirrors the Go xmlReplacer: & < > only (in that order).
private func plistEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
