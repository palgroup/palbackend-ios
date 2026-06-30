import Foundation

// Plist.swift — port of EmitIOSPlistByBundle + writeIOSConfigDict +
// writeIOSOAuthDict (sdk/cli internal/apps/apps.go). Input is
// palbase-config.json (written by `palbase pull-spec`):
//
//   { "<bundleId>": { app_id, identifier, env_preset, base_url, api_key,
//                     oauth?: { apple?: {enabled}, google?: {enabled, client_id, redirect_uri} } }, ... }
//
// Output is the bundle-id-keyed Palbase-Info.plist, BYTE-FOR-BYTE identical to
// the Go emitter (same key order, same indentation, same DOCTYPE, sorted keys).
// The SDK reads this plist from Bundle.main at first `pb.*` access.

enum PlistError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case noEnvironments
    case missingIdentifier(String)
    case duplicateIdentifier(String)
    var description: String {
        switch self {
        case .invalidJSON(let m): return "palbase-config.json is not valid JSON: \(m)"
        case .noEnvironments: return "refusing to write plist: no registered environments to emit"
        case .missingIdentifier(let k): return "refusing to write plist: env \(k) has no identifier (bundle id)"
        case .duplicateIdentifier(let id): return "refusing to write plist: two environments share the bundle id \(id)"
        }
    }
}

// emitPlist renders palbase-config.json bytes into the plist string.
func emitPlist(_ configBytes: Data) throws -> String {
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: configBytes)
    } catch {
        throw PlistError.invalidJSON(error.localizedDescription)
    }
    guard let byBundle = root as? [String: Any], !byBundle.isEmpty else {
        throw PlistError.noEnvironments
    }

    // The config is already keyed by bundle id (identifier). Sort keys the way
    // the Go emitter does (sort.Strings), and guard the same invariants.
    var seenIdentifiers = Set<String>()
    let keys = byBundle.keys.sorted()
    for k in keys {
        guard let env = byBundle[k] as? [String: Any],
              let id = env["identifier"] as? String, !id.isEmpty else {
            throw PlistError.missingIdentifier(k)
        }
        if seenIdentifiers.contains(id) { throw PlistError.duplicateIdentifier(id) }
        seenIdentifiers.insert(id)
    }

    var b = ""
    b += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    b += "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    b += "<plist version=\"1.0\">\n"
    b += "<dict>\n"
    for k in keys {
        let env = byBundle[k] as! [String: Any] // validated above
        b += "\t<key>" + plistEscape(k) + "</key>\n"
        writeConfigDict(&b, env, "\t")
    }
    b += "</dict>\n"
    b += "</plist>\n"
    return b
}

private func writeConfigDict(_ b: inout String, _ env: [String: Any], _ indent: String) {
    b += indent + "<dict>\n"
    // Fixed key order, matching writeIOSConfigDict exactly.
    let fields: [(String, String)] = [
        ("app_id", str(env, "app_id")),
        ("identifier", str(env, "identifier")),
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
