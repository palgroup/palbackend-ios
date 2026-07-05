import Foundation

// Plist.swift — emits Palbase-Info.plist from the single active-env
// palbase-config.json (written by `palbase ios link` / `palbase spec`):
//
//   { app_id, env_preset, base_url, api_key,
//     oauth?: { apple?: {enabled}, google?: {enabled, client_id, redirect_uri} } }
//
// One flat env dict — the active target the CLI selected; no bundle-id→env map
// and no identifier (the SDK sends X-Palbase-Bundle from Bundle.main at request
// time). Output is a flat Palbase-Info.plist (fixed key order, indentation,
// DOCTYPE). The SDK reads this plist from Bundle.main at first `pb.*` access.

enum PlistError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case noEnvironments
    var description: String {
        switch self {
        case .invalidJSON(let m): return "palbase-config.json is not valid JSON: \(m)"
        case .noEnvironments: return "refusing to write plist: no registered environments to emit"
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
    // The config is a SINGLE flat env dict {app_id, env_preset, base_url, api_key,
    // oauth?} — the one active target the CLI selected. No bundle-id→env outer map,
    // and no identifier: the SDK sends X-Palbase-Bundle from Bundle.main at request
    // time, so the config carries no bundle identity.
    guard let env = root as? [String: Any], !env.isEmpty else {
        throw PlistError.noEnvironments
    }

    var b = ""
    b += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    b += "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    b += "<plist version=\"1.0\">\n"
    // The plist IS the single env dict (matching PalbaseAppConfig.load's flat decode).
    writeConfigDict(&b, env, "")
    b += "</plist>\n"
    return b
}

private func writeConfigDict(_ b: inout String, _ env: [String: Any], _ indent: String) {
    b += indent + "<dict>\n"
    // Fixed key order, matching writeIOSConfigDict exactly.
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
