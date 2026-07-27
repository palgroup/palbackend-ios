import Foundation

// Purchases.swift — catalog manifest → typed Swift constants.
//
// Every purchases key is a plain string on the wire: an entitlement key, a product
// key, a limit key, a placement. A paywall written by an AI that types "prro"
// compiles, ships, and silently never unlocks anything. These generated enums turn
// that into a compile error. Same for removal: a key tombstoned in the catalog
// (`removed: true`) stops existing here, so code still referencing it fails to
// build instead of failing in front of a paying customer.
//
// There is deliberately **no price** in the generated types. Prices come from
// StoreKit — localized, current, per-storefront — and from nowhere else. A price in
// the manifest could not be trusted and a hardcoded one is wrong the day the tenant
// changes it. `PurchasesCatalogTests.generatedTypesCarryNoPrice` locks that.
//
// Product raw values are the APPLE store product ids (`storeApps` entries with
// `platform: "apple"`) — this generator emits Swift. A product with no Apple
// mapping is skipped: an iOS app cannot buy it, which is the same narrowing
// palstore already applies when it answers `GET /offerings/{placement}`.

/// The subset of the catalog manifest this generator reads. Unknown fields are
/// ignored by design — the manifest is validated by palstore, not here, and a new
/// field must never break codegen.
struct PurchasesManifest: Decodable {
    /// Every catalog entry this generator touches carries an optional `removed`
    /// tombstone; nothing else about the entry matters for emitting a key.
    struct Entry: Decodable {
        let removed: Bool?
    }

    struct StoreProduct: Decodable {
        let productId: String
    }

    struct StoreApp: Decodable {
        let platform: String
        let products: [String: StoreProduct]?
    }

    let entitlements: [String: Entry]?
    let products: [String: Entry]?
    let limits: [String: Entry]?
    let credits: [String: Entry]?
    let placements: [String: Entry]?
    let storeApps: [String: StoreApp]?
}

/// Emit the `PurchasesCatalog` namespace. Returns "" when the manifest defines
/// nothing emittable, so a project without a catalog gets no dead code.
func emitPurchasesCatalog(_ data: Data) throws -> String {
    let manifest = try JSONDecoder().decode(PurchasesManifest.self, from: data)

    // Apple product ids, keyed by catalog product key. A conflict between two Apple
    // store apps is reported rather than silently resolved: picking one would hand
    // the app a product id it cannot buy.
    var appleProductIDs: [String: String] = [:]
    var conflicts: [String] = []
    for appName in (manifest.storeApps ?? [:]).keys.sorted() {
        let app = manifest.storeApps![appName]!
        guard app.platform == "apple" else { continue }
        for (productKey, mapping) in (app.products ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let existing = appleProductIDs[productKey], existing != mapping.productId {
                conflicts.append(productKey)
                continue
            }
            appleProductIDs[productKey] = mapping.productId
        }
    }
    // Drop every conflicted key: the first-seen id is not "more correct" than the
    // second, and emitting it would hand the app a product id that may not belong to
    // the bundle it ships as. Reported below instead.
    for key in conflicts { appleProductIDs[key] = nil }

    var sections = ""
    sections += emitKeyEnum("Entitlements", live(manifest.entitlements))
    sections += emitKeyEnum(
        "Products", live(manifest.products).filter { appleProductIDs[$0] != nil },
        rawValue: { appleProductIDs[$0]! }
    )
    sections += emitKeyEnum("Limits", live(manifest.limits))
    sections += emitKeyEnum("Credits", live(manifest.credits))
    sections += emitKeyEnum("Placements", live(manifest.placements))

    if sections.isEmpty && conflicts.isEmpty { return "" }

    var b = "\n// MARK: - Purchases catalog (generated — do not edit)\n"
    b += "//\n"
    b += "// Typed keys for `purchases.*`. No price here on purpose: StoreKit is the only\n"
    b += "// source of a price. Regenerated from the catalog; a removed key disappears and\n"
    b += "// code that still uses it stops compiling.\n"
    b += "public enum PurchasesCatalog {\n"
    for key in conflicts.sorted() {
        b += "    // codegen: skipped product " + swiftStringLiteral(key) +
            " — two apple storeApps map it to different product ids\n"
    }
    b += sections
    b += "}\n"
    return b
}

/// Keys that are not tombstoned, sorted for deterministic output.
private func live(_ entries: [String: PurchasesManifest.Entry]?) -> [String] {
    (entries ?? [:]).filter { $0.value.removed != true }.keys.sorted()
}

/// One `String`-backed enum. The raw value is ALWAYS written out — the case name is
/// a sanitized identifier and the wire key is whatever the tenant chose, so the two
/// must never be assumed equal.
private func emitKeyEnum(
    _ name: String,
    _ keys: [String],
    rawValue: (String) -> String = { $0 }
) -> String {
    if keys.isEmpty { return "" }
    var b = "    public enum " + name + ": String, Sendable, CaseIterable {\n"
    // Same collision rule the request/response emitter uses: keep the first key and
    // leave a visible comment, rather than emitting code that does not compile.
    var seen: [String: String] = [:]
    for key in keys {
        let ident = identOf(key)
        if let first = seen[ident] {
            let collision = swiftStringLiteral(key) + " — collides with " + swiftStringLiteral(first)
            b += "        // codegen: skipped duplicate key " + collision
            b += " (both map to Swift `" + unbacktick(ident) + "`)\n"
            continue
        }
        seen[ident] = key
        b += "        case " + ident + " = " + swiftStringLiteral(rawValue(key)) + "\n"
    }
    b += "    }\n"
    return b
}
