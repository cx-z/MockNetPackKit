# MockNetPackKit — Architecture (L2)

> KB layer L2. Read [`overview.md`](overview.md) first. Next: [`code-map.md`](code-map.md).

## Module overview

The SDK is a small set of **singletons with lock-protected state**, orchestrated through a public enum facade.

```
                    ┌──────────────────────────────────────────────┐
                    │            MockNetPackKit (facade)           │
                    │  public start/stop/state/callbacks/register  │
                    └──────────────────────────────────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────────┐
              ▼                       ▼                           ▼
    ┌───────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
    │ ConnectionController│   │ TrafficCaptureController│  │ MockRuleController  │
    │ register · heartbeat│──▶│ capture on/off · batch  │──▶│ rule snapshot · match│
    │ session derivation  │   │ upload · codec slots    │   │ (Method+Path)       │
    └─────────┬───────────┘   └──────────┬──────────────┘   └─────────────────────┘
              │                          │                          ▲
              ▼                          ▼                          │
    ┌───────────────────┐   ┌─────────────────────────┐             │
    │  ConnectionClient  │   │  MockNetPackURLProtocol │─────────────┘
    │  JSON POST/GET     │   │  interceptor: forward / │  serve(mock:)
    │  (skip header)     │   │  serve · record entry  │
    └───────────────────┘   └──────────┬──────────────┘
                                       │
              ┌────────────────────────┴─────────────────────────┐
              ▼                                                  ▼
    ┌───────────────────────────┐                  ┌──────────────────────────┐
    │ URLSessionConfigurationInjector              │ BinaryCodec (Data+gzip)  │
    │ swizzle default/ephemeral │                  │ BodyDecoder/BodyEncoder   │
    └───────────────────────────┘                  └──────────────────────────┘
```

| Module | Singleton | Responsibility |
|---|---|---|
| `MockNetPackKit` (facade) | enum, static | Public API surface; resolves bundle ID/version/OS; forwards to controllers |
| `ConnectionController` | `shared` | Device registration, heartbeat loop, exponential backoff, session-state derivation, 404-stop on unregistered devices; owns serial queue + lock |
| `ConnectionClient` | struct (injected) | Minimal JSON HTTP client (POST/GET) with the `X-MockNetPack-Skip` header; value type, test-injectable |
| `TrafficCaptureController` | `shared` | Turns capture on/off with session state; registers/unregisters the interceptor; batches and uploads traffic (200/8MB/2s); hosts the binary codec dispatch slots |
| `MockNetPackURLProtocol` | class (URLProtocol) | Per-request interception: mock match → serve locally; else forward to real network; assemble `TrafficEntry`; body capture/truncation |
| `MockRuleController` | `shared` | Holds the effective rule snapshot (pulled incrementally by version), `match(method:path:)`, fail-open handling |
| `URLSessionConfigurationInjector` | enum | Swizzles `+defaultSessionConfiguration` / `+ephemeralSessionConfiguration` to inject the interceptor at index 0 |
| `DIDStore` | enum | did generation (UUID) + per-app `UserDefaults` persistence |
| `ServerAddressStore` | enum | M9.2 server-address persistence (`mocknetpack.server.v1.<appID>`, same pattern as `DIDStore`) — saved by scan, read by `start()` for direct connect |
| `QRConnectParser` | enum | M9.2 parses `mocknetpack://connect?v=1&u=<base64url>&a=<appID>&t=<token>` (scheme/version/http(s)+host/appID match/token); `QRConnectPayload` |
| `QRScannerViewController` | class (UIViewController, iOS-only) | M9.2 native AVCaptureSession QR scan, camera permission (denied/unavailable), `QRScanProviding` protocol seam for test injection — **v1.4：`finish()` dismiss 前置 + `dismissIfPresented()` 兜底（扫码流程结束由 connectByScan 调用，防面板静默不收起）**；宿主 Debug 包需 `NSCameraUsageDescription` + `NSLocalNetworkUsageDescription`（iOS 14+ 访问局域网需授权；均 Debug-only 注入，Release 不含，v1.2） |
| `BinaryCodec` | Data extension | Standard gzip compression (zlib) used by the encrypt path |

## Concurrency model

- All mutable state lives in singletons guarded by an `NSLock`; per-module serial `DispatchQueue`s sequence scheduling (connection loop, flush timer).
- `@unchecked Sendable` singletons; callbacks (`onSessionStateChange`, `onConnectionStateChange`, `logHandler`) are dispatched on the **main queue**.
- `URLProtocol` guarantees a single instance's `startLoading`/`stopLoading` don't race; one **shared forwarding `URLSession`** is reused (per-request sessions were the root cause of a 1s-per-request TLS re-handshake regression, M8).

## Data flows

### 1. Startup & heartbeat loop

```
MockNetPackKit.start(server:)
  → ConnectionController.start()
      → did = externalDID ?? DIDStore.did(forApp:)
      → TrafficCaptureController.start()   // inject URLProtocol + swizzle
      → scheduleNext(now: true)            // serial queue
  Loop (one in-flight op at a time):
      register (if !registered) → POST /devices/register
          404 → unregistered = true, stop loop (M7.2.3) — restart app to retry
          ok  → registered = true; scheduleNext(now: true)
      heartbeat → POST /devices/{app}/{did}/heartbeat
          ok  → connected; serverConfig updated (interval 3s/5s dynamic)
                 updateSession(capturing: session != nil)
                 MockRuleController.syncIfNeeded(rulesVersion)   // incremental pull
                 scheduleNext(delay: heartbeatInterval())
          404 → unregistered = true, stop loop (no retry)
          err → offline; exponential backoff 1s→30s; scheduleNext(delay: backoff)
```

### 2. Capture lifecycle (session-driven)

```
heartbeat says session != nil (capturing)
  → TrafficCaptureController.updateSession(capturing: true, sessionID:)
      → flush pending batch (from previous session, if any)
  Any app URLSession (default/ephemeral) now carries MockNetPackURLProtocol (swizzled at index 0)
  → canInit: isCapturing && http(s) && !skipHeader
  → startLoading:
        mock = MockRuleController.match(method, path)
        ── hit  → serve(mock:)   (no real network; record mocked=true entry)
        ── miss → forward via shared session (skipHeader stripped, body rebuilt)
                 → record(entry) on completion
  → record(): bodyParts() (1MB truncation; "[binary N bytes]" + base64 for binary)
              decodedBody() via codec slots (display only)
  → flush(): batch threshold 200 / 8MB / 2s → POST /api/v1/traffic
             failure → drop batch, no retry (F7.6)

heartbeat says session == nil (idle) or stop()
  → updateSession(capturing: false) → pending cleared (session-end semantics)
  → stop() → unregister URLProtocol + uninstall swizzle
```

### 3. Mock match & serve (three-tier body fallback, M7)

```
URLProtocol.startLoading
  → MockRuleController.match(method.uppercased(), path) → MockResponse?
  → serve():
      headers = mock.headers ?? []; ensure Content-Type
      drop header keys containing "proto-res"  // stale key-rotation header must not leak
      body = bodyBase64 (raw bytes)          // ① unedited binary rule — replay exact bytes
           | encoder(bodyText, contentType)  // ② edited text → re-encode via codec
           | UTF-8 text                      // ③ plain text
      record TrafficEntry(mocked: true, request body captured for display)
      deliver HTTPURLResponse to the URLProtocol client
```

### 4. Binary codec pipeline (M6.1)

```
registerBinaryCodec(for:"xcp", compression:.gzip, responseEncrypt:, responseDecrypt:,
                    requestEncrypt: nil, requestDecrypt: nil)
  → TrafficCaptureController installs dispatch closures into slots:
      bodyDecoder     : raw cipher → responseDecrypt → UTF-8 text     (display)
      bodyEncoder     : edited text → UTF-8 → gzip → responseEncrypt  (mock replay)
      requestBodyDecoder: only when requestDecrypt provided (asymmetric request bodies)
      requestBodyEncoder: reserved, no caller yet
  Matching: first registered codec whose contentTypeKey is contained (case-insensitive)
            in the Content-Type header wins.
  Decoder-failure guard: strings containing zlib error macro names (Z_DATA_ERROR …)
            are treated as decode failure, not business payload.
```

### 5. Scan-connect (M9.2, D1–D7)

```
Debug page → MockNetPackKit.connectByScan(from:completion:)
  → QRScannerViewController (AVCaptureSession; cameraDenied/unavailable → error)
  → QRConnectParser.parse(raw, expectedAppID: bundleID)
       appID mismatch → .appMismatch; bad payload → .invalidPayload
  → register POST /devices/register {app, did, pairingToken}   // D1: token auto-register
       403 → .tokenInvalid (QR expired, refresh); other errors → .unreachable
  → success: ConnectionController.stop()            // D6: switch, old server left to expire
      ServerAddressStore.save(newURL)
      ConnectionController.start(server: newURL, …) // direct connect now (A2)
Failure: saved address untouched (R1.6)

start(did:)  (M9.2 no-arg launch)
  → saved address? → start(server:, did:)   // direct connect, no scan needed (A2)
  → none         → startUnconfigured()      // resolves did only; .unconfigured, no network
did = externalDID (e.g. KK UIDevice.deviceID) ?? DIDStore — scan register reuses the SAME did (D7)
```

## Fail-open guarantees

| Scenario | Behavior |
|---|---|
| Server unreachable at startup | No snapshot ⇒ no mocking; traffic capture off; business requests unaffected |
| Rule pull fails after a snapshot exists | Old snapshot kept and still applied |
| Capture session idle | `canInit` false — zero interception |
| SDK own requests | `skipHeader` ⇒ never intercepted |
| Upload failure | Batch dropped; no retry, no local cache |
| Device not registered (404) | Silent stop of the loop; no popups, no retries; recover on app restart after Web registration |
