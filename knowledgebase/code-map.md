# MockNetPackKit — Code Map (L3)

> KB layer L3. Locate the file, then read it. Detailed implementations are not copied here.

## Source tree

```
iOS/MockNetPackKit/
├── Package.swift                       # SwiftPM manifest (products: MockNetPackKit, MockNetPackSmoke)
├── MockNetPackKit.podspec              # CocoaPods podspec (0.2.0-m8; integration with CocoaPods apps)
├── README.md                           # Integration notes (Debug-only, Release exclusion, KK requirements)
├── Sources/
│   ├── MockNetPackKit/                 # ← the SDK implementation
│   └── MockNetPackSmoke/               # CLI smoke tool (executable target)
└── Tests/MockNetPackKitTests/          # unit tests
```

## Files — implementation (`Sources/MockNetPackKit/`)

| File | Role | Key types / functions |
|---|---|---|
| `MockNetPackKit.swift` | Public facade & API surface | `start(server:…)`, `start(did:)` (M9.2 no-arg, saved address or `.unconfigured`), `stop`, `connectByScan(from:completion:)` (M9.2) + internal `connectByScan(scanner:makeClient:)`, `savedServerURL`, `resetServer()`, `ConnectByScanError`, `registerBinaryCodec`, `version`, `did`, `connectionState`, `sessionState`, callbacks; typealiases `BodyDecoder`/`BodyEncoder`; `BinaryCompression` |
| `ConnectionController.swift` | Connection loop: register → heartbeat → session derivation | `shared`, `start(server:appID:externalDID:pairingToken:deviceName:…)`, `startUnconfigured(appID:externalDID:…)` (M9.2), `stop()`, `performCycle()`, `performRegister()`, `heartbeat()`, `heartbeatInterval()`, `advanceBackoff()`; `resolvedAppID`; serial queue + `NSLock` |
| `ConnectionClient.swift` | Minimal JSON HTTP client | `post(_:body:as:)`, `get(_:as:)`; always sets `X-MockNetPack-Skip: 1`; `ConnectionClientError` |
| `TrafficCaptureController.swift` | Capture on/off, batching, upload, codec slots | `shared`, `start/stop`, `updateSession(capturing:sessionID:)`, `record(_:)`, `flush()`, `registerBinaryCodec(...)`, `bodyDecoder`/`bodyEncoder`/`requestBodyDecoder`/`requestBodyEncoder`, `isDecoderErrorText` |
| `MockNetPackURLProtocol.swift` | Per-request interceptor | `canInit`, `startLoading`, `stopLoading`, `serve(mock:)`, `record(...)`, `readBody(of:rewriting:)`, `bodyParts`, `sanitizedBody`, `decodedBody`, `skipHeader`, `bodyLimit`, shared forwarding session |
| `MockRuleController.swift` | Effective rule snapshot + matching | `shared`, `syncIfNeeded(client:app:did:serverVersion:)`, `match(method:path:)`, `applyForTesting`, `reset` |
| `URLSessionConfigurationInjector.swift` | Swizzle `default/ephemeral` session configs | `install()`, `uninstall()`; inserts interceptor at index 0 (required for canInit ordering) |
| `DIDStore.swift` | did generation/persistence | `did(forApp:defaults:)`, `reset(forApp:defaults:)` — UUID + UserDefaults, key `mocknetpack.did.v1.<appID>` |
| `ServerAddressStore.swift` | M9.2 server-address persistence | `save/load/clear(forApp:defaults:)` — UserDefaults, key `mocknetpack.server.v1.<appID>` |
| `QRConnectParser.swift` | M9.2 QR payload parser | `parse(_:expectedAppID:)` → `QRConnectPayload{serverURL,appID,token}`; `QRConnectParseError` (notMockNetPack/unsupportedVersion/invalidServer/missingAppID/appMismatch/missingToken); base64url decode |
| `QRScannerViewController.swift` | M9.2 native QR scanner (iOS-only, `#if canImport(UIKit)`) | `QRScanProviding` protocol + `QRScannerViewController` (AVCaptureSession + AVCaptureMetadataOutput(.qr), camera permission); `QRScanError` (cameraDenied/cameraUnavailable) |
| `BinaryCodec.swift` | gzip compression | `Data.gzipCompressed()` (standard gzip via zlib, `MAX_WBITS+16`) — decompression stays in the business `decrypt` closure |
| `Models.swift` | Contract models: RegisterDeviceRequest (**+appName v0.9.0**, +pairingToken/deviceName M9), DeviceView, session/traffic/rule payloads |

## Files — smoke tool (`Sources/MockNetPackSmoke/main.swift`)

CLI for manual end-to-end verification against a local `mockd` (Admin :4290). Starts the SDK, fires 3 requests/sec to `engineBase` while capturing, prints state changes. Usage documented in the file header; run `swift run MockNetPackSmoke [serverURL] [engineBase]`.

## Files — tests (`Tests/MockNetPackKitTests/`)

| File | Covers |
|---|---|
| `ConnectionControllerTests.swift` | register/heartbeat loop, 404-stop, backoff, session derivation |
| `QRConnectParserTests.swift` | M9.2 QR parsing: valid/base64url, wrong scheme/host/version, invalid server, missing appID/token, appMismatch |
| `ServerAddressStoreTests.swift` | M9.2 address save/load/clear, per-app isolation, invalid value rejection |
| `ConnectByScanTests.swift` | M9.2 facade: unconfigured start, scan success (token in register, did reuse, address persisted, connects), D6 switch, failures keep saved address, cancelled/camera errors |
| `TrafficCaptureTests.swift` | capture on/off, batching thresholds, flush, drop-on-failure |
| `MockURLProtocol.swift` | Stub URLProtocol used to simulate the real network in tests |
| `MockRuleTests.swift` | match semantics (Method+Path, case-insensitivity), snapshot apply |
| `BinaryCodecTests.swift` | gzip round-trip, codec dispatch, error-text guard |
| `DIDStoreTests.swift` | did persistence/scoping per app |
| `MockNetPackKitTests.swift` | facade-level checks |

## Where to change things (common tasks)

| Task | Touch |
|---|---|
| Add/change a server API the SDK calls | `Models.swift` (schema) + `ConnectionClient` call sites in `ConnectionController` / `TrafficCaptureController` / `MockRuleController` |
| Change heartbeat behavior | `ConnectionController.performCycle()` / `heartbeatInterval()` / `advanceBackoff()` |
| Change capture batching | `TrafficCaptureController` (`maxBatchCount`, `maxBatchBytes`, `flushInterval`, `flush()`) |
| Change mock matching | `MockRuleController.match()` (matching key semantics) |
| Change body capture/truncation | `MockNetPackURLProtocol.bodyParts()` / `bodyLimit` / `readBody(of:rewriting:)` |
| Change codec registration/fallback order | `TrafficCaptureController.registerBinaryCodec` + `MockNetPackURLProtocol.serve(mock:)` body fallback |
| Change interception coverage | `URLSessionConfigurationInjector` (swizzled constructors) + `canInit` |
| Change did identity | `DIDStore` + `ConnectionController.start(externalDID:)` |
| Change scan-connect (QR format/token flow) | `QRConnectParser` + `MockNetPackKit.connectByScan` + `ServerAddressStore`; contract in `server/openapi/mocknetpack.yaml` `/pairing-tokens` + register `pairingToken` |
| Protocol alignment check | `Models.swift` vs `server/openapi/mocknetpack.yaml` (keep in sync) |
