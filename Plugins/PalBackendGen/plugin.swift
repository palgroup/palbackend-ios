import PackagePlugin
import Foundation

// Build-tool plugin: when a consumer app target contains `palbase.openapi.json`,
// generate typed namespaced backend calls into it at build time.
//
// Sandboxed (no network) — it reads the LOCAL openapi.json. Fetching that file
// from the backend is `palbase backend types`' job (runs outside the build,
// with the project anon key; `palbase backend deploy` triggers it automatically).
@main
struct PalBackendGen: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let sourceTarget = target.sourceModule else { return [] }

        // Find `palbase.openapi.json` among the target's files.
        let spec = sourceTarget.sourceFiles.first { $0.url.lastPathComponent == "palbase.openapi.json" }
        guard let spec else { return [] }   // no spec → nothing to generate

        let tool = try context.tool(named: "PalBackendCodegen")
        let outDir = context.pluginWorkDirectoryURL.appendingPathComponent("GeneratedSources")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outFile = outDir.appendingPathComponent("PalbaseEndpoints.swift")

        return [
            .buildCommand(
                displayName: "Generating Palbase backend types from palbase.openapi.json",
                executable: tool.url,
                arguments: [spec.url.path, "-o", outFile.path],
                inputFiles: [spec.url],
                outputFiles: [outFile]
            )
        ]
    }
}
