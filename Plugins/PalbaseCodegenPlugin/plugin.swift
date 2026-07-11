import PackagePlugin
import Foundation

// PalbaseCodegen — build-tool plugin. Reads the shared committed
// `.palbase/openapi.json` plus the optional fixed iOS/macOS config slots and runs
// palbase-swiftgen at build time. It emits PalbaseGenerated.swift and one
// Palbase-Info.plist envelope that the SDK selects by compile-time platform.
// .buildCommand (not .prebuildCommand) keeps the inputs in the dependency graph.
// No network — the plugin sandbox forbids it.
//
// Inputs DON'T need Xcode target membership: the plugin resolves them from the
// project/package directory, so they never clutter the project navigator. It
// still declares the existing files as command inputFiles, so changes retrigger
// codegen. `.palbase/` also holds the CLI's own link config (`config.json`) — a
// different file, coexisting fine.

@main
struct PalbaseCodegenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        return try buildCommands(
            workDir: context.pluginWorkDirectoryURL,
            palbaseDir: context.package.directoryURL.appendingPathComponent(".palbase")
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension PalbaseCodegenPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        return try buildCommands(
            workDir: context.pluginWorkDirectoryURL,
            palbaseDir: context.xcodeProject.directoryURL.appendingPathComponent(".palbase")
        )
    }
}
#endif

// Shared command construction for both the SwiftPM and Xcode entry points.
private let generatorSourceNames = ["main.swift", "Parse.swift", "Emit.swift", "Plist.swift"]

private func generatorSourceDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PalbaseCodegenPlugin
        .deletingLastPathComponent() // Plugins
        .deletingLastPathComponent() // package root
        .appendingPathComponent("Sources/palbase-swiftgen")
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func buildCommands(workDir: URL, palbaseDir: URL) throws -> [Command] {
    guard let inputs = try palbaseCodegenInputs(palbaseDir: palbaseDir) else {
        // No spec fetched yet → nothing to generate (clean no-op, same as before).
        return []
    }
    let openapi = inputs.openAPI

    let outSwift = workDir.appendingPathComponent("PalbaseGenerated.swift")
    let outPlist = workDir.appendingPathComponent("Palbase-Info.plist")

    var args = ["--openapi", openapi.path, "--out-swift", outSwift.path]
    var outputs = [outSwift]
    var cmdInputs = [openapi]
    if let iosConfig = inputs.iosConfig {
        args += ["--ios-config", iosConfig.path]
        cmdInputs.append(iosConfig)
    }
    if let macOSConfig = inputs.macOSConfig {
        args += ["--macos-config", macOSConfig.path]
        cmdInputs.append(macOSConfig)
    }
    args += ["--out-plist", outPlist.path]
    outputs.append(outPlist)

    // Xcode 26 compiles executable-target dependencies of an Xcode build-tool
    // plugin for the destination SDK. Such a binary cannot run on the build
    // host (`DYLD_ROOT_PATH not set for simulator program`). Compile the small,
    // Foundation-only generator for the host inside the sandboxed build command
    // and run it immediately. Source files are declared inputs, so this command
    // remains incremental and fully offline.
    let generatorDir = generatorSourceDirectory()
    let generatorSources = generatorSourceNames.map { generatorDir.appendingPathComponent($0) }
    cmdInputs.append(contentsOf: generatorSources)
    let hostTool = workDir.appendingPathComponent("palbase-swiftgen-host")
    let compile = (["/usr/bin/env", "-u", "SDKROOT", "/usr/bin/xcrun", "swiftc"] + generatorSources.map(\.path) + [
        "-module-cache-path", workDir.appendingPathComponent("ModuleCache").path,
        "-o", hostTool.path,
    ]).map(shellQuote).joined(separator: " ")
    let run = ([hostTool.path] + args).map(shellQuote).joined(separator: " ")
    let script = "set -eu; \(compile) && \(run)"

    return [.buildCommand(
        displayName: "Palbase codegen (\(openapi.lastPathComponent))",
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        inputFiles: cmdInputs,
        outputFiles: outputs
    )]
}
