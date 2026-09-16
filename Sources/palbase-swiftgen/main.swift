import Foundation

// palbase-swiftgen — CLI entry. Two INDEPENDENT halves, either or both per run:
//
//   the client:  --openapi <spec> --out-swift <path>
//   the plist:   [--ios-config <json>] [--macos-config <json>] --out-plist <path>
//
// N COPIES OF THE PLIST, ONE PER ENVIRONMENT, IS THE DESIGN. Every environment
// owns a flat directory in the customer's checkout
// (`palbase/environments/<env>/`) holding that environment's spec, its platform
// config slots, its generated client AND its own plist; the BUILD picks which
// directory compiles, so the app bundle carries exactly one plist and the SDK
// has no name left to resolve. The plist used to be written once for the whole
// project, carrying an environment map the app indexed at runtime — that cost a
// resolution step the customer had to configure, and unconfigured it did not
// fail, it silently talked to the wrong environment. Do not merge the halves
// back into one file.
//
// The two halves stay independent because they read different inputs and a run
// may legitimately have one without the other: the client comes from that
// environment's `openapi.json`, the plist from its `ios-config.json` /
// `macos-config.json`, and an environment carrying a contract but no Apple slot
// generates a client and no plist. The Palbase CLI holds the list of
// environments and issues the two invocations per environment itself.
//
// Passing neither half is an error, as is half of a pair (a spec with nowhere to
// write, a config with no --out-plist) — silence there would look like success.
//
// No network: every input is a local file. This is the build-time half of the
// codegen split; Palbase CLI link writes the per-environment OpenAPI specs and
// platform config slots out-of-band.

struct Args {
    var openapi: String?
    var iosConfig: String?
    var macOSConfig: String?
    var outSwift: String?
    var outPlist: String?
}

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var i = 0
    while i < argv.count {
        let k = argv[i]
        let v = i + 1 < argv.count ? argv[i + 1] : nil
        switch k {
        case "--openapi": a.openapi = v; i += 2
        case "--ios-config": a.iosConfig = v; i += 2
        case "--macos-config": a.macOSConfig = v; i += 2
        case "--out-swift": a.outSwift = v; i += 2
        case "--out-plist": a.outPlist = v; i += 2
        default: i += 1
        }
    }
    return a
}

/// What ONE invocation was asked to produce. Either half may be absent — see the
/// header: the two halves read different inputs and either can be the only one
/// a given run has.
struct GenerationPlan: Equatable {
    struct SwiftJob: Equatable {
        let openapi: String
        let outSwift: String
    }
    struct PlistJob: Equatable {
        let iosConfig: String?
        let macOSConfig: String?
        let outPlist: String
    }

    let swiftJob: SwiftJob?
    let plistJob: PlistJob?
}

enum ArgsError: Error, CustomStringConvertible {
    case nothingToGenerate
    case incompleteSwiftHalf
    case incompletePlistHalf

    var description: String {
        switch self {
        case .nothingToGenerate:
            return "nothing to generate: pass --openapi with --out-swift, " +
                "--ios-config/--macos-config with --out-plist, or both pairs"
        case .incompleteSwiftHalf:
            return "--openapi and --out-swift go together: one without the other is a spec " +
                "with nowhere to write, or an output with nothing to write into it"
        case .incompletePlistHalf:
            return "--ios-config/--macos-config and --out-plist go together: one without the " +
                "other is a config nobody reads, or a plist with no config to emit"
        }
    }
}

/// Turn the parsed flags into the jobs to run, or refuse. Pure, so the flag
/// contract the Palbase CLI invokes against is testable without running the tool.
func planGeneration(_ args: Args) throws -> GenerationPlan {
    let swiftJob: GenerationPlan.SwiftJob?
    switch (args.openapi, args.outSwift) {
    case let (openapi?, outSwift?):
        swiftJob = .init(openapi: openapi, outSwift: outSwift)
    case (nil, nil):
        swiftJob = nil
    default:
        throw ArgsError.incompleteSwiftHalf
    }

    let hasPlatformConfig = args.iosConfig != nil || args.macOSConfig != nil
    let plistJob: GenerationPlan.PlistJob?
    switch (hasPlatformConfig, args.outPlist) {
    case (true, let outPlist?):
        plistJob = .init(
            iosConfig: args.iosConfig, macOSConfig: args.macOSConfig, outPlist: outPlist
        )
    case (false, nil):
        plistJob = nil
    default:
        throw ArgsError.incompletePlistHalf
    }

    guard swiftJob != nil || plistJob != nil else { throw ArgsError.nothingToGenerate }
    return GenerationPlan(swiftJob: swiftJob, plistJob: plistJob)
}


func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

/// Why a contract cannot yield roles, in the words the user needs.
///
/// A VALUE, not an `exit(1)`. `die` ends the process, so no assertion can ever
/// read what it said — and the sentence IS the requirement here: it has to name
/// the two steps in order. A message nothing can measure is a message that rots.
struct RolesNotInContract: Error, CustomStringConvertible {
    let description: String
}

/// The role definitions as they travel INSIDE the contract (`x-palbase-roles`),
/// handed back as the same `{"roles": [...]}` bytes `emitRoles` already reads.
///
/// There is no sibling file to find any more, so there is no path rule to get
/// wrong — which is exactly what the retired one did: it derived
/// `<spec>.roles.json` while the CLI wrote `roles.json`, the two never met, and
/// every Apple client shipped without its role types until v0.62.1.
///
/// ABSENT IS NO LONGER AN ANSWER. A contract fetched by a CLI carrying this
/// change always has the field; one without it is STALE, and emitting nothing
/// would silently drop constants somebody's code already names.
func rolesBody(inContract spec: Data) throws -> Data {
    guard let root = try JSONSerialization.jsonObject(with: spec) as? [String: Any] else {
        throw RolesNotInContract(description: "the contract is not a JSON object")
    }
    guard let field = root["x-palbase-roles"] else {
        throw RolesNotInContract(description:
            "this contract carries no `x-palbase-roles`, so it predates roles travelling "
            + "inside the document. Two steps, in this order: upgrade `@palbase/backend` "
            + "and push the project, then run `palbase link` to refresh the contract.")
    }
    // PRESENT BUT BODILESS IS ALSO A REFUSAL (FR-021), and it is checked HERE
    // rather than in emitRoles so the emitter stays exactly as it is. `{}` is not
    // "no roles" — it is a contract whose producer answered about roles without
    // listing any, which is what the stack itself refuses to serve. Emitting
    // nothing for it would delete constants somebody's code already names.
    // `{"roles": []}` is NOT this case: that is a stack with no roles, and it
    // legitimately emits nothing.
    guard let body = field as? [String: Any], body["roles"] is [Any] else {
        throw RolesNotInContract(description:
            "this contract's `x-palbase-roles` carries no roles list, so what the stack "
            + "defines cannot be read from it. Refresh the contract; if it comes back the "
            + "same, the stack is serving a malformed document.")
    }
    return try JSONSerialization.data(withJSONObject: body)
}

let args = parseArgs(Array(CommandLine.arguments.dropFirst()))
let plan: GenerationPlan
do {
    plan = try planGeneration(args)
} catch {
    die("error: \(error)")
}

if let job = plan.swiftJob {
    let specData: Data
    do {
        specData = try Data(contentsOf: URL(fileURLWithPath: job.openapi))
    } catch {
        die("error: cannot read openapi spec at \(job.openapi): \(error)")
    }

    // Parse → emit. Parse.swift / Emit.swift provide these (Phase 1 port).
    let ops: [SwiftOp]
    do {
        ops = try parseOpenAPIForSwift(specData)
    } catch {
        die("error: \(error)")
    }

    var swift = emitSwift(ops, rooms: try parseRoomsForSwift(specData))

    // Roles → typed role/permission enums, appended to the same generated file
    // for the same reason the catalog is: one committed codegen artifact. They
    // come from the SAME BYTES the operations did — see rolesBody(inContract:).
    do {
        swift += try emitRoles(rolesBody(inContract: specData))
    } catch {
        die("error: \(error)")
    }

    do {
        try swift.write(toFile: job.outSwift, atomically: true, encoding: .utf8)
    } catch {
        die("error: cannot write swift to \(job.outSwift): \(error)")
    }
}

// The plist is not derived from any spec. The platform configs of ONE environment
// produce one `{ios?, macos?}` envelope for that environment — flat slots, no
// environment map (see Plist.swift).
if let job = plan.plistJob {
    do {
        let iosData = try job.iosConfig.map {
            try Data(contentsOf: URL(fileURLWithPath: $0))
        }
        let macOSData = try job.macOSConfig.map {
            try Data(contentsOf: URL(fileURLWithPath: $0))
        }
        let plist = try emitPlist(iosConfigBytes: iosData, macOSConfigBytes: macOSData)
        try plist.write(toFile: job.outPlist, atomically: true, encoding: .utf8)
    } catch {
        die("error: plist emit failed: \(error)")
    }
}
