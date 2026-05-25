# palbackend-ios

The **Palbe** SDK — one import for iOS apps with a managed Palbase backend.

```swift
import Palbe

pb.configure(apiKey: "pb_abc123m_c…")   // anon (publishable) key

let room = try await pb.rooms.create(.init(name: "lobby"))   // generated, typed
try await pb.auth.signIn(email: "a@b.com", password: "…")
```

`import Palbe` gives a single entry point — `pb`. Generated typed endpoint calls
(`pb.rooms.create(...)`), an untyped escape hatch (`pb.call` / `pb.upload`), and
auth (`pb.auth.*`) — and nothing else. Transport, token storage, the embedded auth
client, and App Attest are all internal. There is no direct-database door: a
backend app talks to **its backend**, which owns the business rules.

> Building a smaller app that talks directly to the database with RLS? Use the
> granular [`palbase-ios`](https://github.com/palgroup/palbase-ios) modules
> (`PalbaseAuth` + `PalbaseDB` + …) instead.

## Install (SwiftPM)

```swift
.package(url: "https://github.com/palgroup/palbackend-ios.git", from: "0.2.1")
// target dependency:
.product(name: "Palbe", package: "palbackend-ios")
```

## Backend RPC — `pb`

Every `defineEndpoint` you ship is reachable as an RPC (`POST /rpc/{name}`). Use the
generated typed call (preferred) or the untyped escape hatch:

```swift
// Generated (see "Generated typed calls" below):
let room = try await pb.rooms.create(.init(name: "lobby"))

// Untyped — always available, no codegen:
struct CreateRoom: Encodable, Sendable { let name: String }
struct Room: Decodable, Sendable { let id: String; let name: String }
let room2: Room = try await pb.call("rooms.create", CreateRoom(name: "lobby"))
```

### Generated typed calls (autocomplete + compile-time safety)

Instead of hand-writing models and string operation names, generate them from your
backend's published OpenAPI. Calls then become namespaced and fully typed:

```swift
let room = try await pb.rooms.create(.init(name: "lobby", capacity: 50))
// room: Rooms.Create.Output  →  room.id, room.name, room.capacity, room.tags
```

The generator is built into the `palbase` CLI — no Node, no SwiftPM plugin, no
extra tooling. The untyped `pb.call("rooms.create", input)` always works without
codegen; the typed surface is opt-in via one step.

#### Setup: one Xcode Run Script build phase

Add a **Run Script** phase to your app target (Target → Build Phases → + → New Run
Script Phase). On every build it fetches the live contract and regenerates the
typed surface — Debug builds read your local `palbase backend dev`, Release/CI the
deployed backend:

```sh
if which palbase >/dev/null; then
  ENV=$([ "$CONFIGURATION" = "Debug" ] && echo local || echo remote)
  palbase backend types --lang swift \
    --env "$ENV" \
    --out "$DERIVED_FILE_DIR/PalbaseEndpoints.swift"
else
  echo "warning: palbase CLI not found — skipping typed codegen"
fi
```

Then, in the same phase:
- **Output Files:** add `$(DERIVED_FILE_DIR)/PalbaseEndpoints.swift` — Xcode
  compiles it and re-runs the script only when needed.
- Set **"Based on dependency analysis"** off if you want it to run every build.

Notes:
- Requires the `palbase` CLI on the build machine (`brew install …` / your install).
- The Run Script phase is **not network-sandboxed**, which is exactly why this is
  the single, fully-automatic path (a SwiftPM build plugin can't reach the network).
  Keep `ENABLE_USER_SCRIPT_SANDBOXING = NO` for the target (the default for apps).
- The generated file lands in `DerivedData` — never committed, always current.

That's the whole codegen story: one CLI, one build phase. No plugin to install, no
`openapi.json` to commit.

- **Typed, named errors** — `BackendError` decodes the standard envelope, including
  Zod field errors (`.validation(fields:)`), `.server(code:…)`, `.rateLimited`,
  `.unauthorized`. `switch` on them; never parse status codes by hand.
- **Idempotency** — mutating calls carry an `Idempotency-Key` reused across retries,
  so a dropped-then-retried `POST` is not applied twice.
- **Upload with progress**:

```swift
struct Out: Decodable, Sendable { let url: String }
let out: Out = try await pb.upload(
    "avatars.put", fileURL: localURL, fields: ["caption": "me"],
    constraints: UploadConstraints(maxSize: 5_000_000, allowedTypes: ["image/png"])
) { progress in print(progress.fraction) }
```

  With `constraints`, an oversize or wrong-type file is rejected client-side before
  any bytes are sent.

## Auth — `pb.auth`

Auth is embedded; there is no separate module to import. The surface is the core
set most apps need:

```swift
try await pb.auth.signUp(email: "a@b.com", password: "…")
try await pb.auth.signIn(email: "a@b.com", password: "…")
let user = try await pb.auth.getUser()
let signedIn = await pb.auth.isSignedIn
let unsub = await pb.auth.onAuthStateChange { event, session in /* … */ }
try await pb.auth.signOut()
```

The session token is managed internally and attached to every backend call; you
never handle tokens directly.

## App Attest (anti-abuse)

Prove requests come from a genuine build of your app on real Apple hardware —
requests replayed from an extracted key are rejected server-side.

```swift
PalBackend.configure(apiKey: "pb_abc123m_c…", appAttest: true)
```

Flag-gated, all-or-nothing. Off by default; leave it off in development and on the
Simulator (App Attest is unavailable there). The project must also have App Attest
enabled server-side. When on, the SDK enrolls a Secure-Enclave key on first use and
attaches a fresh, request-bound assertion to every call — entirely behind the
façade; you write no attestation code.

## Design

- Foundation only — no third-party dependencies.
- Swift 6 strict concurrency.
- One product, one import, one closed surface.

> Server-side dependencies (must exist for full function): backend honors
> `Idempotency-Key` on `/rpc/*`; App Attest enrollment/verification endpoints
> (`/attest/challenge`, `/attest/enroll`) gated on the project's App Attest flag.
