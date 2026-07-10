import Foundation

// palbase-swiftgen — CLI entry. Parses a local OpenAPI 3.1 spec plus optional
// fixed-platform configs and writes PalbaseGenerated.swift and Palbase-Info.plist.
//
//   palbase-swiftgen --openapi <path> \
//                    [--ios-config <path>] [--macos-config <path>] \
//                    --out-swift <path> [--out-plist <path>]
//
// No network: every input is a local file. This is the build-time half of the
// codegen split; Palbase CLI link writes shared OpenAPI and platform slots
// out-of-band.

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

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = parseArgs(Array(CommandLine.arguments.dropFirst()))
guard let openapiPath = args.openapi else { die("error: --openapi <path> required") }
guard let outSwiftPath = args.outSwift else { die("error: --out-swift <path> required") }
guard let outPlistPath = args.outPlist else { die("error: --out-plist <path> required") }
guard args.iosConfig != nil || args.macOSConfig != nil else {
    die("error: --ios-config or --macos-config required")
}

let specData: Data
do {
    specData = try Data(contentsOf: URL(fileURLWithPath: openapiPath))
} catch {
    die("error: cannot read openapi spec at \(openapiPath): \(error)")
}

// Parse → emit. Parse.swift / Emit.swift provide these (Phase 1 port).
let ops: [SwiftOp]
do {
    ops = try parseOpenAPIForSwift(specData)
} catch {
    die("error: \(error)")
}

let swift = emitSwift(ops)
do {
    try swift.write(toFile: outSwiftPath, atomically: true, encoding: .utf8)
} catch {
    die("error: cannot write swift to \(outSwiftPath): \(error)")
}

// Plist config is not derived from the spec. Platform slots produce one
// envelope containing every available config.
do {
    let iosData = try args.iosConfig.map {
        try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    let macOSData = try args.macOSConfig.map {
        try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    let plist = try emitPlist(iosConfigBytes: iosData, macOSConfigBytes: macOSData)
    try plist.write(toFile: outPlistPath, atomically: true, encoding: .utf8)
} catch {
    die("error: plist emit failed: \(error)")
}
