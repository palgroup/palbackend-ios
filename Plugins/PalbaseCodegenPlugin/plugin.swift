import PackagePlugin
import Foundation

// PalbaseCodegen — build-tool plugin. Finds the committed openapi.json (+
// optional palbase-config.json) in the target's inputs and runs palbase-swiftgen
// over them at build time, emitting PalbaseGenerated.swift (+ Palbase-Info.plist)
// into the plugin work dir. .buildCommand (not .prebuildCommand): wired into the
// dependency graph so it re-runs ONLY when the spec changes. No network — the
// plugin sandbox forbids it; the spec is fetched out-of-band by `palbase pull-spec`.

@main
struct PalbaseCodegenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let src = target.sourceModule else { return [] }
        let inputs = src.sourceFiles.map(\.url)
        return try buildCommands(
            tool: try context.tool(named: "palbase-swiftgen").url,
            workDir: context.pluginWorkDirectoryURL,
            inputs: inputs
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension PalbaseCodegenPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let inputs = target.inputFiles.map(\.url)
        return try buildCommands(
            tool: try context.tool(named: "palbase-swiftgen").url,
            workDir: context.pluginWorkDirectoryURL,
            inputs: inputs
        )
    }
}
#endif

// Shared command construction for both the SPM and Xcode entry points.
private func buildCommands(tool: URL, workDir: URL, inputs: [URL]) throws -> [Command] {
    guard let openapi = inputs.first(where: { $0.lastPathComponent == "openapi.json" }) else {
        // No spec in this target → nothing to generate (clean no-op).
        return []
    }
    let config = inputs.first(where: { $0.lastPathComponent == "palbase-config.json" })

    let outSwift = workDir.appendingPathComponent("PalbaseGenerated.swift")
    let outPlist = workDir.appendingPathComponent("Palbase-Info.plist")

    var args = ["--openapi", openapi.path, "--out-swift", outSwift.path]
    var outputs = [outSwift]
    var cmdInputs = [openapi]
    if let config {
        args += ["--config", config.path, "--out-plist", outPlist.path]
        outputs.append(outPlist)
        cmdInputs.append(config)
    }

    return [.buildCommand(
        displayName: "Palbase codegen (\(openapi.lastPathComponent))",
        executable: tool,
        arguments: args,
        inputFiles: cmdInputs,
        outputFiles: outputs
    )]
}
