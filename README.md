# Palbe — Palbase managed-backend SDK for iOS

`import Palbe` gives your app a single entry point, **`pb`** — typed backend
calls, auth, feature flags, and analytics — wired to your Palbase project. No
setup boilerplate, no transport to manage: the SDK self-configures from a
generated contract file and refreshes it on every Xcode build.

> Distributed as a closed-source binary (XCFramework). This is the public
> distribution repo you add via SPM; the SDK source is private.

- **Platforms:** iOS 18+, macOS 15+, tvOS 18+, watchOS 11+
- **Swift:** 6 (strict concurrency)
- **Dependencies:** none (Foundation only)

---

## Install

Add the package in Xcode (**File ▸ Add Package Dependencies…**) or in your
`Package.swift`:

```swift
.package(url: "https://github.com/palgroup/palbackend-ios", from: "0.5.0")
```

Then add `Palbe` to your target and `import Palbe`.

## Configure (one command, then never again)

You don't call `configure()` in code. Instead, run the Palbase CLI **once** to
wire codegen into your Xcode project:

```bash
palbase mobile setup ios --ref <your-project-ref>
```

This adds an Xcode **Run Script** build phase that, on every build:

- generates typed `pb.<namespace>.<operation>(...)` methods from your backend's
  endpoints, and
- writes `PalbaseGenerated.json` (URL, API key, OAuth providers) into the app
  bundle.

The SDK reads that file lazily on the first `pb.*` access and configures itself.
Because the script runs on every build, the URL / key / OAuth config always
reflect what's in Studio.

> To re-generate manually (e.g. after changing endpoints), run
> `palbase mobile codegen ios`.

---

## Usage

Everything hangs off the global `pb`.

### Typed endpoint calls (generated)

The CLI generates one typed method per backend endpoint:

```swift
import Palbe

let room = try await pb.rooms.create(.init(name: "lobby"))
let todos = try await pb.todos.list()
```

These are the preferred surface — fully typed input and output, with typed
errors when an endpoint declares them.

### Untyped escape hatch

When you don't have (or don't want) codegen — prototyping, scripts — call an
endpoint by its path:

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
