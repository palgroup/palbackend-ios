# Palbe — Palbase managed-backend SDK for iOS, iPadOS, and macOS

`import Palbe` gives your app a single entry point, **`pb`** — typed backend
calls, auth, feature flags, and analytics — wired to your Palbase project. No
setup boilerplate, no transport to manage: the SDK self-configures from a
committed contract file, and an SPM build-tool plugin regenerates the typed
client on every Xcode build — offline, no CLI on PATH.

> Distributed as a closed-source binary (XCFramework). This is the public
> distribution repo you add via SPM; the SDK source is private.

- **Platforms:** iOS/iPadOS 18+ (arm64 device and Simulator) and macOS 15+
  (Apple Silicon/arm64). The distributed XCFramework does not include Mac
  Catalyst, Intel macOS, tvOS, watchOS, or visionOS slices.
- **Swift:** 6 (strict concurrency)
- **Public API:** `Palbe`'s exported API is Foundation-only. The product also
  carries the pinned binary runtime needed for voice/video calls.

---

## Install

One package URL vends everything (Firebase-style): the `Palbe` binary SDK **and**
the `PalbaseCodegen` build-tool plugin. Add it in Xcode (**File ▸ Add Package
Dependencies…**) or in your `Package.swift`:

```swift
.package(url: "https://github.com/palgroup/palbackend-ios", from: "0.26.1")
```

Add **two** products from this one package to your app target: the `Palbe`
library (gives you `import Palbe` and `pb`) and the `PalbaseCodegen` build-tool
plugin (generates the typed `pb.<ns>.<op>(...)` methods on every build). In Xcode,
both are offered when you add the package; the plugin attaches under target ▸
**Build Phases** ▸ **Run Build Tool Plug-ins**. In a SwiftPM target:

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "Palbe", package: "palbackend-ios")],
    plugins: [.plugin(name: "PalbaseCodegen", package: "palbackend-ios")]
)
```

The `Palbe` product already includes its media runtime as flat SwiftPM binary
targets so Xcode signs them for device builds. Do not add LiveKit, a second calls
product, or an `enable()` call. SwiftPM necessarily makes the packaging modules
`LiveKitWebRTC` and `RustLiveKitUniFFI` visible to a target that links this
multi-target product; they are unsupported implementation artifacts, not Palbe
API, and may change without compatibility guarantees. Do not import them.

The exact third-party license and NOTICE texts ship both inside
`Palbe.framework` and in [`ThirdPartyLicenses`](ThirdPartyLicenses/README.md).

### Headless agents and CI

Xcode normally asks a human to **Trust & Enable** the build-tool plugin on its
first run. A terminal-only agent or CI worker must add
`-skipPackagePluginValidation` to every `xcodebuild` invocation instead:

```bash
xcodebuild \
  -project MyApp.xcodeproj \
  -scheme MyApp \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation \
  build
```

Before using the flag, verify that `Package.resolved` resolves
`palbackend-ios` from the official
`https://github.com/palgroup/palbackend-ios` package at the expected reviewed
version/revision. The flag bypasses Xcode's interactive approval for every
package plugin in that build; it does not skip Palbase codegen. Do not modify
Xcode's private trust database, set a global validation bypass, or add
`-skipPackageSignatureValidation`. Interactive Xcode users should keep the
normal one-time **Trust & Enable** flow.

## Configure: fetch the spec once, the plugin does the rest

You don't call `configure()` in code, and there is no live codegen at build time.
The flow splits into a one-time **fetch** (online, CLI) and an automatic
**generate** (offline, the plugin):

1. **Link each platform** with the Palbase CLI from your project root. Run the
   command for every platform your project ships:

   ```bash
   palbase ios link
   palbase macos link
   ```

   Each command prompts you to select a Palbase product. The first link for a
   platform creates its app; later runs reuse the exact app ID persisted in the
   local `.palbase/config.json`. They do not search for or reuse an arbitrary
   remote app just because its metadata matches. The commands write one shared
   API contract plus fixed platform config slots:

   ```text
   .palbase/
     config.json
     openapi.json
     ios/palbase-config.json
     macos/palbase-config.json
   ```

   `config.json` records the selected product and linked platform app IDs. Each link
   updates only its own platform slot and preserves the other one. An iOS-only
   project needs only the `ios` slot; a macOS-only project needs only `macos`.
   The build plugin reads these fixed paths directly. It does not inspect Xcode
   target names or use bundle IDs to choose a config.

   Commit `.palbase/openapi.json` and the generated `.palbase/ios/` /
   `.palbase/macos/` slot files. Keep `.palbase/config.json` local and
   gitignored; it is CLI state, not a build input. The committed files need no
   Xcode target membership, never clutter the project navigator, and let a fresh
   checkout run codegen offline.

2. **Build.** On every Xcode build the `PalbaseCodegen` plugin runs **offline**
   over those committed files and generates the typed
   `pb.<namespace>.<operation>(...)` methods plus one `Palbase-Info.plist`
   containing the available `ios` / `macos` config slots. No `palbase` CLI on
   PATH, no network in the build.

At runtime the SDK reads `Palbase-Info.plist` from `Bundle.main` lazily on the
first `pb.*` access. A macOS build reads only `macos`; an iOS/iPadOS build reads
only `ios`. A missing current-platform slot fails configuration instead of using
the other platform's values. Missing or empty `app_id`, `base_url`, or `api_key`
also fails configuration. `app_id` plus the publishable API key identify the
linked app. `X-Palbase-Bundle` carries the host bundle ID only as runtime
metadata. Re-run the matching link command to refresh; the next build regenerates.

---

## Usage

Everything hangs off the global `pb`.

### Typed endpoint calls (generated)

The plugin generates one typed method per backend endpoint:

```swift
import Palbe

let room = try await pb.rooms.create(.init(name: "lobby"))
let todos = try await pb.todos.list()
```

These are the preferred surface — fully typed input and output, with typed
errors when an endpoint declares them.

### Untyped escape hatch

When you don't have (or don't want) generated methods — prototyping, scripts —
call an endpoint by its path:

```swift
struct CreateTodo: Encodable { let title: String }
struct Todo: Decodable { let id: String; let title: String }

let todo: Todo = try await pb.call("todos/create", CreateTodo(title: "Buy milk"))
```

`pb.call` and the generated methods emit byte-identical requests — same
idempotency, App Attest, and header handling.

### File upload

```swift
struct UploadResult: Decodable { let url: String }

let result: UploadResult = try await pb.upload(
    "media/avatar",
    fileURL: localURL,
    onProgress: { progress in
        print("\(progress.fractionCompleted * 100)%")
    }
)
```

### Auth

```swift
// Email + password
try await pb.auth.signUp(email: "a@b.com", password: "…")
try await pb.auth.signIn(email: "a@b.com", password: "…")

// Native social sign-in
try await pb.auth.signInWithApple()
try await pb.auth.signInWithGoogle()   // client config baked in by codegen

try await pb.auth.signOut()
let user = try await pb.auth.getUser()
```

Session storage and token refresh are automatic (Keychain-backed). Observe
auth state for UI gating:

```swift
let unsubscribe = await pb.auth.onAuthStateChange { state in
    switch state {
    case .signedIn(let user): /* show home */ break
    case .signedOut:          /* show login */ break
    }
}
// keep `unsubscribe` alive for the listener's lifetime
```

`onAuthEvent` is a separate hook for side effects (analytics, toasts, debug
logs) including `tokenRefreshed` and `signedOut(.sessionExpired)`.

### Feature flags

`pb.flags` is observable — read a flag in a SwiftUI `body` and the view
re-renders when **that** flag changes (and only that flag):

```swift
struct ContentView: View {
    var body: some View {
        if pb.flags.bool("new_checkout", default: false) {
            NewCheckout()
        } else {
            ClassicCheckout()
        }
    }
}
```

Also available: `isEnabled`, string / int / double / json accessors, the
`changes` `AsyncStream`, and `onChange` for non-SwiftUI callers.

### Analytics

```swift
await pb.analytics.capture("checkout_started", properties: ["plan": "pro"])
await pb.analytics.screen("Home")
// identify() is called automatically on sign-in
```

### Voice/video calls

Calls are part of `Palbe`; no extra product or registration step is required:

```swift
let call = try await chat.startCall(media: .audioVideo)

if let incoming = pb.messaging.incomingCall {
    let answered = try await incoming.accept()
    // Bind answered.state / answered.participants in SwiftUI.
}
```

Add `NSMicrophoneUsageDescription` and, for video, `NSCameraUsageDescription` to
the app's Info.plist. A call becomes `.active` only after the real SFU transport
connects; there is no signaling-only fallback that reports a false connection.

---

## App Attest

On native iOS/iPadOS, App Attest is **server-controlled and lazy** — there's no
client flag to set. When an app/environment binding enables it, the backend
answers a request with `401 app_attest_required`; the SDK enrolls the device and
retries the request once, transparently. macOS never
attempts App Attest. You don't write any attestation code.

## Error handling

Backend calls throw `BackendError` (`.notConfigured`, `.validation`,
`.unauthorized`, `.forbidden`, `.notFound`, `.rateLimited`, `.server`,
`.decode`, `.transport`, `.appAttest`). Auth throws `AuthError`. Endpoints that
declare an `errors` map generate a typed error enum you can `catch` first,
falling back to `catch let e as BackendError`.

## Debug tracing (opt-in)

The transport logs every request/response via `os.Logger` (subsystem
`studio.palbase.sdk`, category `http`) with secrets redacted. It's **off by
default**; flip it on per-run from the Xcode scheme:

- environment variable `PALBASE_DEBUG=1`, or
- launch argument `-PalbaseDebug YES`

View in Console.app, or:

```bash
xcrun simctl spawn booted log stream --predicate 'subsystem == "studio.palbase.sdk"'
```

---

Closed-source binary (XCFramework). Distributed from the private
`palgroup/palbackend-ios-src` source repo.
