# palbackend-ios

The **Palbe** SDK for iOS — one import for apps with a managed Palbase backend.

```swift
import Palbe

pb.configure(apiKey: "pb_abc123m_c…")            // anon (publishable) key

let room = try await pb.rooms.create(.init(name: "lobby"))   // generated, typed
try await pb.auth.signIn(email: "a@b.com", password: "…")
```

`import Palbe` gives a single entry point — `pb`. Generated typed endpoint calls
(`pb.rooms.create(...)`), an untyped escape hatch (`pb.call` / `pb.upload`), and
auth (`pb.auth.*`). Nothing else: transport, tokens, App Attest are internal, and
there is no direct-database door. Shipped as a closed-source XCFramework.

## Install (SwiftPM)

```swift
.package(url: "https://github.com/palgroup/palbackend-ios.git", from: "0.1.0")
```

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "Palbe", package: "palbackend-ios")],
    // Optional: generate typed pb.<endpoint> calls at build time.
    plugins: [.plugin(name: "PalBackendGen", package: "palbackend-ios")]
)
```

## Typed calls (codegen)

1. Fetch the contract (anon key, config-aware local/remote):

   ```bash
   palbase backend types              # remote (Kong gateway)
   palbase backend types --env local  # local `palbase backend dev`
   ```

   Writes `palbase.openapi.json` into your app target. `palbase backend deploy`
   runs it automatically.

2. The `PalBackendGen` build plugin regenerates the typed `pb.*` surface from
   `palbase.openapi.json` on every `swift build` — no manual codegen, no
   committed generated code. (Without the plugin, the untyped
   `pb.call(name:_:)` always works.)

## App Attest

```swift
pb.configure(apiKey: "pb_abc123m_c…", appAttest: true)
```

Flag-gated anti-abuse: only a genuine build of your app on real Apple hardware
can call the backend. Off by default; leave off in dev / Simulator.

---

This repository distributes the SDK as a binary. The source is maintained
privately; only the build-time codegen plugin is open here.
