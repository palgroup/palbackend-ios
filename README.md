# Palbe — Palbase managed-backend SDK for iOS

`import Palbe` gives your app a single entry point, **`pb`** — typed backend
calls, auth, feature flags, and analytics — wired to your Palbase project. No
setup boilerplate, no transport to manage: the SDK self-configures from a
committed contract file, and an SPM build-tool plugin regenerates the typed
client on every Xcode build — offline, no CLI on PATH.

> Distributed as a closed-source binary (XCFramework). This is the public
> distribution repo you add via SPM; the SDK source is private.

- **Platforms:** iOS 18+, macOS 15+, tvOS 18+, watchOS 11+
- **Swift:** 6 (strict concurrency)
- **Dependencies:** none (Foundation only)

---

## Install

One package URL vends everything (Firebase-style): the `Palbe` binary SDK **and**
the `PalbaseCodegen` build-tool plugin. Add it in Xcode (**File ▸ Add Package
Dependencies…**) or in your `Package.swift`:

```swift
.package(url: "https://github.com/palgroup/palbackend-ios", from: "0.5.0")
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

## Configure: fetch the spec once, the plugin does the rest

You don't call `configure()` in code, and there is no live codegen at build time.
The flow splits into a one-time **fetch** (online, CLI) and an automatic
**generate** (offline, the plugin):

1. **Fetch the contract** with the Palbase CLI — run it once, and again whenever
   you change endpoints or want fresh config:

   ```bash
   palbase pull-spec --ref <your-project-ref> --app <your-app-id>
   ```

   This writes two files into a committed `Palbase/` directory in your app:
   `openapi.json` (your backend's API contract) and `palbase-config.json` (one
   entry per registered bundle id: URL, publishable key, OAuth providers).
   **Commit both** — they're the input the plugin builds from.

2. **Build.** On every Xcode build the `PalbaseCodegen` plugin runs **offline**
   over those committed files and generates the typed
   `pb.<namespace>.<operation>(...)` methods plus a per-env `Palbase-Info.plist`.
   No `palbase` CLI on PATH, no network in the build.

At runtime the SDK reads `Palbase-Info.plist` from `Bundle.main` lazily on the
first `pb.*` access and configures itself — picking the entry whose bundle id
matches the running app, and refusing to send if none matches. Re-run
`palbase pull-spec` to pull updated endpoints/config; the next build regenerates.

> Flags: `palbase pull-spec --ref <ref> [--branch <branch>] [--app <app-id>]
> [--out-dir ./Palbase]`. Without `--app` only `openapi.json` is written (types
> only, no runtime config).

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
            LegacyCheckout()
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

---

## App Attest

App Attest is **server-controlled, lazy** — there's no client flag to set. When
your project enables it for a branch, the backend answers a request with
`401 app_attest_required`; the SDK then enrolls the device and retries the
request once, transparently. You don't write any attestation code.

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
