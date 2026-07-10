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
            tool: try context.tool(named: "palbase-swiftgen").url,
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
            tool: try context.tool(named: "palbase-swiftgen").url,
            workDir: context.pluginWorkDirectoryURL,
            palbaseDir: context.xcodeProject.directoryURL.appendingPathComponent(".palbase")
        )
    }
}
#endif

// Shared command construction for both the SwiftPM and Xcode entry points.
private func buildCommands(tool: URL, workDir: URL, palbaseDir: URL) throws -> [Command] {
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

    return [.buildCommand(
        displayName: "Palbase codegen (\(openapi.lastPathComponent))",
        executable: tool,
        arguments: args,
        inputFiles: cmdInputs,
        outputFiles: outputs
    )]
}
