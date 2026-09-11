import Foundation

// Plist.swift — emits Palbase-Info.plist from the per-platform config file
// `palbase link` writes into ONE environment's directory
// (`palbase/environments/<env>/`):
//
//   { app_id, base_url, api_key,
//     oauth?: <target-specific public OAuth snapshot>,
//     purchases?: { base_url, publishable_key } }
//
// Output is an `{ios?, macos?}` envelope whose values are those same flat
// fields. A single available platform is valid; absent platforms stay absent.
// The format uses fixed key order, tab indentation, and DOCTYPE.
//
// THE ENVIRONMENT MAP IS GONE, AND THE REASON IT EXISTED IS GONE WITH IT.
//
// This file used to emit `{default_environment, environments: {...}}` — every
// environment of the project in ONE plist, the app picking one at runtime by
// name (`PALBASE_ENV`, resolved by `PalbaseEnvironmentSelection`). The recorded
// justification was that the plist lived at ONE path, so pointing an app at
// another environment meant OVERWRITING it: two build configurations could not
// name prod and the local stack at the same time.
//
// That constraint was in the LAYOUT, not in the plist. Every environment now has
// its own directory and its own plist, and the BUILD picks one — measured on a
// real Xcode 26.6 build with `EXCLUDED_SOURCE_FILE_NAMES` +
// `INCLUDED_SOURCE_FILE_NAMES` over `$(PALBASE_ENV)`, both directions, with the
// unselected environment's plist never entering the app bundle. So the app
// bundle carries exactly ONE plist, and nothing has a name left to resolve.
//
// Do not reintroduce the map: its cost is a runtime resolution step the customer
// has to configure, and that step is what made a build in the `Local`
// configuration sign up against the MAIN environment's address while every build
// setting still read `local`.

enum PlistError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case noPlatformConfigs
    case invalidRequiredField(String)
    case missingAPIKeyField(String)

    var description: String {
        switch self {
        case .invalidJSON(let m): return "palbase-config.json is not valid JSON: \(m)"
        case .noPlatformConfigs:
            return "refusing to write plist: no platform config was given"
        case .invalidRequiredField(let field):
            return "palbase-config.json is missing nonempty required field \(field)"
        case .missingAPIKeyField(let field):
            return "palbase-config.json is missing required field \(field) — it must be present " +
                "as a string, though it may be empty while that environment has no key yet"
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
        writeEnvironmentDict(&b, ios, "\t")
    }
    if let macOS {
        b += "\t<key>macos</key>\n"
        writeEnvironmentDict(&b, macOS, "\t")
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

/// One platform's slot: this environment's own fields, flat.
private func decodePlatform(_ configBytes: Data, platform: String) throws -> [String: Any] {
    let root: Any
    do {
        root = try decodeConfigJSON(configBytes)
    } catch {
        throw PlistError.invalidJSON(error.localizedDescription)
    }
    guard let fields = root as? [String: Any] else {
        throw PlistError.invalidJSON("the \(platform) config is not a JSON object")
    }
    // The key carries the project's identity, so there is no separate ref to
    // require — and requiring one meant requiring a copy that could disagree
    // with it (measured 2026-08-16: link wrote "selfhost" beside a key saying
    // "project", and everything derived from the wrong one named a channel
    // nobody else used).
    for field in ["app_id", "base_url"] {
        guard let value = fields[field] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlistError.invalidRequiredField(field)
        }
    }
    // Present but possibly empty: a `local` environment linked while its stack
    // was down has no key yet. The SDK refuses to BOOT such a config with a
    // typed error naming `palbase start`; writing it out is how the app finds
    // out the environment exists at all.
    guard fields["api_key"] is String else {
        throw PlistError.missingAPIKeyField("api_key")
    }
    if fields["auth"] != nil || fields["socialAuth"] != nil {
        throw PlistError.invalidRequiredField("oauth (use the oauth field)")
    }
    if let oauth = fields["oauth"] {
        try validateOAuthSnapshot(oauth, platform: platform, apiKey: fields["api_key"] as! String)
    }
    for feature in ["oauth", "notifications", "integrity"] {
        if let value = fields[feature] { try validateConfigPlistValue(value, path: feature) }
    }
    return fields
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
    for feature in ["oauth", "notifications", "integrity"] {
        if let value = env[feature] {
            b += indent + "\t<key>" + feature + "</key>\n"
            writeConfigValue(&b, value, indent + "\t")
        }
    }
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

private func str(_ m: [String: Any], _ k: String) -> String { (m[k] as? String) ?? "" }
private func bool(_ m: [String: Any], _ k: String) -> Bool { (m[k] as? Bool) ?? false }

private func plistBool(_ v: Bool) -> String { v ? "<true/>" : "<false/>" }

// plistEscape mirrors the Go xmlReplacer: & < > only (in that order).
private func plistEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
