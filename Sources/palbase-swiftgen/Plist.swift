import Foundation

// Plist.swift — emits Palbase-Info.plist from the per-platform config files
// written by `palbase ios link` and `palbase macos link`:
//
//   { default_environment: "main",
//     environments: {
//       "<name>": { app_id, base_url, api_key,
//                   oauth?: { apple?: {enabled}, google?: {enabled, client_id, redirect_uri} },
//                   purchases?: { base_url, publishable_key } }, … } }
//
// Output is an `{ios?, macos?}` envelope whose values are those same
// `{default_environment, environments}` slots. A single available platform is
// valid; absent platforms stay absent. The format uses fixed key order,
// alphabetically sorted environment names, tab indentation, and DOCTYPE.
//
// EVERY environment of the project rides in ONE plist, and the build picks one by
// name (`PALBASE_ENV`, resolved by `PalbaseEnvironmentSelection` in the SDK). The
// file used to carry exactly one environment, so pointing an app at another one
// meant OVERWRITING it — two build configurations could not name prod and the
// local stack at the same time, and comparing them meant re-running link between
// builds.

enum PlistError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case noPlatformConfigs
    case noEnvironments(String)
    case blankEnvironmentName(String)
    case invalidRequiredField(String)
    case missingAPIKeyField(String)
    case unknownDefaultEnvironment(requested: String, available: [String])

    var description: String {
        switch self {
        case .invalidJSON(let m): return "palbase-config.json is not valid JSON: \(m)"
        case .noPlatformConfigs:
            return "refusing to write plist: no platform config was given"
        case .noEnvironments(let platform):
            return "refusing to write plist: the \(platform) config declares no environments"
        case .blankEnvironmentName(let platform):
            return "refusing to write plist: the \(platform) config has an environment whose " +
                "name is blank — no PALBASE_ENV value can ever select it"
        case .invalidRequiredField(let field):
            return "palbase-config.json is missing nonempty required field \(field)"
        case .missingAPIKeyField(let field):
            return "palbase-config.json is missing required field \(field) — it must be present " +
                "as a string, though it may be empty while that environment has no key yet"
        case .unknownDefaultEnvironment(let requested, let available):
            let names = available.isEmpty ? "(none)" : available.joined(separator: ", ")
            return "palbase-config.json: default_environment \"\(requested)\" names no " +
                "environment (it carries: \(names))"
        }
    }
}

// Platform-envelope emitter. Each argument is the JSON from its matching
// fixed slot. Missing one platform never borrows the other platform's config.
func emitPlist(iosConfigBytes: Data?, macOSConfigBytes: Data?) throws -> String {
    guard iosConfigBytes != nil || macOSConfigBytes != nil else {
        throw PlistError.noPlatformConfigs
    }

    let ios = try iosConfigBytes.map { try decodePlatform($0, platform: "ios") }
    let macOS = try macOSConfigBytes.map { try decodePlatform($0, platform: "macos") }

    var b = plistHeader
    b += "<dict>\n"
    if let ios {
        b += "\t<key>ios</key>\n"
        writePlatformDict(&b, ios, "\t")
    }
    if let macOS {
        b += "\t<key>macos</key>\n"
        writePlatformDict(&b, macOS, "\t")
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

/// One platform's slot: the default environment plus every environment, in
/// sorted order so the emitted bytes are deterministic.
private struct PlatformSlot {
    let defaultEnvironment: String
    let environments: [(name: String, fields: [String: Any])]
}

private func decodePlatform(_ configBytes: Data, platform: String) throws -> PlatformSlot {
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: configBytes)
    } catch {
        throw PlistError.invalidJSON(error.localizedDescription)
    }
    guard let slot = root as? [String: Any] else {
        throw PlistError.invalidJSON("the \(platform) config is not a JSON object")
    }
    guard let environments = slot["environments"] as? [String: Any], !environments.isEmpty else {
        throw PlistError.noEnvironments(platform)
    }
    guard let defaultEnvironment = slot["default_environment"] as? String,
          !defaultEnvironment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PlistError.invalidRequiredField("default_environment")
    }
    // A default that names nothing is refused HERE, at generate time, rather
    // than at app boot on a developer's device.
    guard environments[defaultEnvironment] != nil else {
        throw PlistError.unknownDefaultEnvironment(
            requested: defaultEnvironment, available: environments.keys.sorted()
        )
    }

    var validated: [(name: String, fields: [String: Any])] = []
    for name in environments.keys.sorted() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlistError.blankEnvironmentName(platform)
        }
        guard let fields = environments[name] as? [String: Any] else {
            throw PlistError.invalidRequiredField("environments.\(name)")
        }
        // The key carries the project's identity, so there is no separate ref to
        // require — and requiring one meant requiring a copy that could disagree
        // with it (measured 2026-08-16: link wrote "selfhost" beside a key saying
        // "project", and everything derived from the wrong one named a channel
        // nobody else used).
        for field in ["app_id", "base_url"] {
            guard let value = fields[field] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PlistError.invalidRequiredField("environments.\(name).\(field)")
            }
        }
        // Present but possibly empty: a `local` environment linked while its
        // stack was down has no key yet. The SDK refuses to BOOT such an
        // environment with a typed error naming `palbase start`; writing it out
        // is how the app finds out which environments exist at all.
        guard fields["api_key"] is String else {
            throw PlistError.missingAPIKeyField("environments.\(name).api_key")
        }
        validated.append((name, fields))
    }
    return PlatformSlot(defaultEnvironment: defaultEnvironment, environments: validated)
}

private func writePlatformDict(_ b: inout String, _ slot: PlatformSlot, _ indent: String) {
    b += indent + "<dict>\n"
    b += indent + "\t<key>default_environment</key>\n"
    b += indent + "\t<string>" + plistEscape(slot.defaultEnvironment) + "</string>\n"
    b += indent + "\t<key>environments</key>\n"
    b += indent + "\t<dict>\n"
    for (name, fields) in slot.environments {
        b += indent + "\t\t<key>" + plistEscape(name) + "</key>\n"
        writeEnvironmentDict(&b, fields, indent + "\t\t")
    }
    b += indent + "\t</dict>\n"
    b += indent + "</dict>\n"
}

private func writeEnvironmentDict(_ b: inout String, _ env: [String: Any], _ indent: String) {
    b += indent + "<dict>\n"
    // Fixed key order for every environment.
    // No `kind`: the SDK no longer decides anything from the Environment's
    // classification. The in-app console is gated on a server-controlled user
    // flag instead, so a developer can open it for ONE user on a shipped build
    // — a decision the plist cannot carry and a build cannot make.
    let fields: [(String, String)] = [
        ("app_id", str(env, "app_id")),
        ("base_url", str(env, "base_url")),
        ("api_key", str(env, "api_key")),
    ]
    for (key, val) in fields {
        b += indent + "\t<key>" + plistEscape(key) + "</key>\n"
        b += indent + "\t<string>" + plistEscape(val) + "</string>\n"
    }
    // OPTIONAL, and written only when the link found one.
    //
    // The sealing chain is verified root-first, so an app hosted by somebody
    // other than the fleet has to be TOLD which root its stack hangs from — it
    // cannot derive one and must not fetch one from the server it is checking.
    // Until this line existed the SDK read `sealed_root` and nothing anywhere
    // wrote it, so every self-hosted app fell back to roots that could not
    // verify its stack and the sealing layer was inert for all of them.
    //
    // Absent when the stack has no chain: the SDK then keeps its compiled-in
    // roots, which is the correct behaviour for a fleet app. An empty string
    // here would read as a configured root and fail at the first sealed request.
    if let sealedRoot = env["sealed_root"] as? String, !sealedRoot.isEmpty {
        b += indent + "\t<key>sealed_root</key>\n"
        b += indent + "\t<string>" + plistEscape(sealedRoot) + "</string>\n"
    }
    writeOAuthDict(&b, env["oauth"] as? [String: Any], indent + "\t")
    writePurchasesDict(&b, env["purchases"] as? [String: Any], indent + "\t")
    b += indent + "</dict>\n"
}

// The palstore endpoint `PalbePurchases` boots from — a DIFFERENT service from the
// `base_url` above, with its own key. It rides in this plist rather than a file of its
// own so an app has one generated config, not two that can disagree about which
// environment it is: the platform writes both halves of the environment in one commit.
// It sits INSIDE the environment because a dev environment's palstore key is not the
// production one.
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
