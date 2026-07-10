import Foundation

struct PalbaseCodegenInputs {
    let openAPI: URL
    let iosConfig: URL?
    let macOSConfig: URL?
}

enum PalbaseCodegenInputError: Error, LocalizedError, CustomStringConvertible {
    case missingPlatformConfig

    var description: String {
        "PalbaseCodegen found .palbase/openapi.json but no platform config. "
            + "Run `palbase ios link` and/or `palbase macos link`, then rebuild."
    }

    var errorDescription: String? { description }
}

/// Resolve the fixed platform slots without inspecting the build target.
///
/// At least one platform config is required. The plugin always passes every
/// available slot to the generator so each compiled SDK can select only its own
/// platform at runtime.
func palbaseCodegenInputs(
    palbaseDir: URL,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
) throws -> PalbaseCodegenInputs? {
    let openAPI = palbaseDir.appendingPathComponent("openapi.json")
    guard fileExists(openAPI) else { return nil }

    let iosURL = palbaseDir
        .appendingPathComponent("ios", isDirectory: true)
        .appendingPathComponent("palbase-config.json")
    let macOSURL = palbaseDir
        .appendingPathComponent("macos", isDirectory: true)
        .appendingPathComponent("palbase-config.json")
    let iosConfig = fileExists(iosURL) ? iosURL : nil
    let macOSConfig = fileExists(macOSURL) ? macOSURL : nil
    guard iosConfig != nil || macOSConfig != nil else {
        throw PalbaseCodegenInputError.missingPlatformConfig
    }
    return PalbaseCodegenInputs(
        openAPI: openAPI,
        iosConfig: iosConfig,
        macOSConfig: macOSConfig
    )
}
