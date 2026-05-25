// swift-tools-version:6.0
import PackageDescription

// palbackend-ios — the managed-backend SDK (binary distribution).
//
// `import Palbe` gives a single entry point `pb`: generated typed endpoint
// calls (`pb.rooms.create(...)`), the untyped escape hatch (`pb.call`/
// `pb.upload`), and auth (`pb.auth.*`). The SDK ships as a closed-source
// XCFramework — `Palbe` is a binaryTarget, so consumers see only the public
// API (Cmd+Click shows no implementation). Source lives in a private repo.
//
// The codegen plugin (PalBackendGen + PalBackendCodegen) ships as source — it
// is a build-time OpenAPI→Swift translator the consumer's build runs, not SDK
// logic. Add the plugin to your app target to get typed `pb.*` calls from a
// local `palbase.openapi.json` (fetched by `palbase backend types`).
let package = Package(
    name: "Palbe",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "Palbe", targets: ["Palbe"]),
        .plugin(name: "PalBackendGen", targets: ["PalBackendGen"]),
    ],
    targets: [
        .binaryTarget(
            name: "Palbe",
            url: "https://github.com/palgroup/palbackend-ios/releases/download/v0.2.0/Palbe.xcframework.zip",
            checksum: "da47db05efb8a816c76e43fb78cb9ff0274e111abf7af4361a7b96e45510a0e4"
        ),
        .executableTarget(name: "PalBackendCodegen"),
        .plugin(
            name: "PalBackendGen",
            capability: .buildTool(),
            dependencies: ["PalBackendCodegen"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
