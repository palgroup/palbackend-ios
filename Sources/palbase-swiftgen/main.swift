import Foundation

// palbase-swiftgen — CLI entry. Two INDEPENDENT halves, either or both per run:
//
//   the client:  --openapi <spec> --out-swift <path>
//   the plist:   [--ios-config <json>] [--macos-config <json>] --out-plist <path>
//
// They are independent because they have different cardinalities. A project has
// ONE plist (it carries every environment) but as many clients as it has
// environments, each generated from THAT environment's own spec — dev is usually
// ahead of production, and an app built for dev must not compile against
// production's endpoint set. The Palbase CLI holds the list of environments, so
// it runs this once per environment for the client and once for the plist;
// requiring both halves on every run would either rewrite one plist N times or
// scatter N copies of it beside the clients.
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
/// header: the two halves have different cardinalities.
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

    // Roles → typed role/permission enums, appended to the same generated file for
    // the same reason the catalog is: one committed codegen artifact.
    //
    // The path is DERIVED, not passed. `palbase spec` writes the definitions beside
    // the contract and differing only in extension (`main.json` → `main.roles.json`)
    // precisely so a generator handed the spec can find them BY RULE — the CLI that
    // writes both lives in another repository, and a second setting somebody has to
    // keep in step is a setting that drifts.
    //
    // No file is an ANSWER, not a failure: a checkout whose last `palbase spec`
    // predates roles has none, and that project must still generate the client it
    // generated before, byte for byte. A file that is there but does not parse is
    // the opposite — the definitions were fetched and something is wrong with them,
    // and emitting no types would hand back a client missing exactly what was added.
    let rolesPath = URL(fileURLWithPath: job.openapi)
        .deletingPathExtension()
        .appendingPathExtension("roles.json")
    if FileManager.default.fileExists(atPath: rolesPath.path) {
        do {
            swift += try emitRoles(Data(contentsOf: rolesPath))
        } catch {
            die("error: cannot emit roles from \(rolesPath.path): \(error)")
        }
    }

    do {
        try swift.write(toFile: job.outSwift, atomically: true, encoding: .utf8)
    } catch {
        die("error: cannot write swift to \(job.outSwift): \(error)")
    }
}

// The plist is not derived from any spec. The platform configs produce one
// envelope carrying every environment of every available platform.
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
