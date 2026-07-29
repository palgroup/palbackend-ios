import Foundation

// Plist.swift — emits Palbase-Info.plist from the fixed platform config slots
// written by `palbase ios link` and `palbase macos link`:
//
//   { app_id, environment_ref, base_url, api_key,
//     oauth?: { apple?: {enabled}, google?: {enabled, client_id, redirect_uri} },
//     purchases?: { base_url, publishable_key } }
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
    for field in ["app_id", "environment_ref", "base_url", "api_key"] {
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
    // No `kind`: the SDK no longer decides anything from the Environment's
    // classification. The in-app console is gated on a server-controlled user
    // flag instead, so a developer can open it for ONE user on a shipped build
    // — a decision the plist cannot carry and a build cannot make.
    let fields: [(String, String)] = [
        ("app_id", str(env, "app_id")),
        ("environment_ref", str(env, "environment_ref")),
        ("base_url", str(env, "base_url")),
        ("api_key", str(env, "api_key")),
    ]
    for (key, val) in fields {
        b += indent + "\t<key>" + plistEscape(key) + "</key>\n"
        b += indent + "\t<string>" + plistEscape(val) + "</string>\n"
    }
    writeOAuthDict(&b, env["oauth"] as? [String: Any], indent + "\t")
    writePurchasesDict(&b, env["purchases"] as? [String: Any], indent + "\t")
    b += indent + "</dict>\n"
}

// The palstore endpoint `PalbePurchases` boots from — a DIFFERENT service from the
// `base_url` above, with its own key. It rides in this plist rather than a file of its
// own so an app has one generated config, not two that can disagree about which
// environment it is: the platform writes both halves of the slot in one commit.
//
// `publishable_key` is a `pk_`, and shipping it inside the binary is the design, not a
// leak (SPEC-purchases-v1 §5: everything it authorises is scoped to the caller's own
// subject and moves no money). The tenant's `sk_` is its backend's and must never reach
// this file — `configure` rejects one loudly if it ever does.
private func writePurchasesDict(_ b: inout String, _ purchases: [String: Any]?, _ indent: String) {
    guard let purchases else { return }
    let fields = [("base_url", str(purchases, "base_url")), ("publishable_key", str(purchases, "publishable_key"))]
    // Both or neither. A half-written block reaches the app as a `configure` that throws
    // `invalidConfiguration` on the first `purchases.*` call — strictly worse than an
    // absent block, which reads as "this app sells nothing" and is the common case.
    guard fields.allSatisfy({ !$0.1.isEmpty }) else { return }

    b += indent + "<key>purchases</key>\n"
    b += indent + "<dict>\n"
    for (key, val) in fields {
        b += indent + "\t<key>" + plistEscape(key) + "</key>\n"
        b += indent + "\t<string>" + plistEscape(val) + "</string>\n"
    }
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
