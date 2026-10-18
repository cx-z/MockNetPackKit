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
| `TrafficCaptureController` | `shared` | Buffers startup HTTP until the first session result (200 entries / 8 MiB encoded); turns capture on/off with session state; isolates HTTP request generations; registers/unregisters the interceptor; batches and uploads traffic (200/8MB/2s); hosts the binary codec dispatch slots |
| `MockNetPackURLProtocol` | class (URLProtocol) | Per-request interception: mock match → serve locally; else forward to real network; assemble `TrafficEntry`; body capture/truncation |
| `MockRuleController` | `shared` | Holds the effective rule snapshot (pulled incrementally by version), `match(method:path:)`, fail-open handling |
| `URLSessionConfigurationInjector` | enum | Swizzles `+defaultSessionConfiguration` / `+ephemeralSessionConfiguration` to inject the interceptor at index 0 |
| `DIDStore` | enum | did generation (UUID) + per-app `UserDefaults` persistence |
| `ServerAddressStore` | enum |  server-address persistence (`mocknetpack.server.v1.<appID>`, same pattern as `DIDStore`) — saved by scan, read by `start()` for direct connect |
| `QRConnectParser` | enum |  parses `mocknetpack://connect?v=1&u=<base64url>&a=<appID>&t=<token>` (scheme/version/http(s)+host/appID match/token); `QRConnectPayload` |
| `QRScannerViewController` | class (UIViewController, iOS-only) | native AVCaptureSession QR scan, camera permission (denied/unavailable), `QRScanProviding` protocol seam for test injection — `finish()` dismiss happens first + `dismissIfPresented()` fallback (called by `connectByScan` when the scan flow ends, so the panel is never left silently open); the host Debug build needs `NSCameraUsageDescription` + `NSLocalNetworkUsageDescription` (iOS 14+ requires authorization to reach the LAN; both are Debug-only injections, absent from Release) |
| `BinaryCodec` | Data extension | Standard gzip compression (zlib) used by the encrypt path |

## Concurrency model

- All mutable state lives in singletons guarded by an `NSLock`; per-module serial `DispatchQueue`s sequence scheduling (connection loop, flush timer).
- `@unchecked Sendable` singletons; callbacks (`onSessionStateChange`, `onConnectionStateChange`, `logHandler`) are dispatched on the **main queue**.
- `URLProtocol` guarantees a single instance's `startLoading`/`stopLoading` don't race; one **shared forwarding `URLSession`** is reused (per-request sessions were the root cause of a 1s-per-request TLS re-handshake regression).

## Data flows

### 1. Startup & heartbeat loop

```
MockNetPackKit.start(server:)
  → ConnectionController.start()
      → did = externalDID ?? DIDStore.did(forApp:)
      → TrafficCaptureController.start()   // inject URLProtocol + swizzle; enable bounded startup HTTP buffer
      → scheduleNext(now: true)            // serial queue
  Loop (one in-flight op at a time):
      register (if !registered) → POST /devices/register
          404 → unregistered = true, stop loop  — restart app to retry
          ok  → registered = true; scheduleNext(now: true)
      heartbeat → POST /devices/{app}/{did}/heartbeat
          ok  → connected; serverConfig updated (interval 3s/5s dynamic)
                 updateSession(capturing: session != nil)
                 MockRuleController.syncIfNeeded(rulesVersion)   // incremental pull
                 scheduleNext(delay: heartbeatInterval())
          404 → unregistered = true, stop loop (no retry)
          err → offline; exponential backoff 1s→30s; scheduleNext(delay: backoff)

The server's TrafficEntry carries `seq` (a per-session arrival sequence number acting as an incremental cursor),
stamped by the server in arrival order during UploadTraffic — the SDK does not carry, see, or consume it;
it is used by the Web/MCP/CLI query side; the SDK contract (register/heartbeat/upload/mock-rules pull) is unchanged.
Hit traffic additionally reports matchedRuleId — MockRuleController.match
writes the matched rule's ID into MockResponse.ruleId, and serve records it into TrafficEntry.matchedRuleId;
it is non-empty only when mocked=true; Web display and replay semantics are unchanged.
```

### 2. Capture lifecycle (session-driven)

```
configured start, before the first heartbeat result
  → canInit: httpCaptureGeneration != nil && http(s) && !skipHeader
  → forward immediately, without mocking or waiting for the platform
  → record completed entries in memory (earliest 200 entries / 8 MiB encoded maximum)
  → no upload until an active session is confirmed

heartbeat says session != nil (capturing)
  → TrafficCaptureController.updateSession(capturing: true, sessionID:)
      → first active result: detach startup buffer with device/session identity under the capture lock;
        upload that batch outside the lock, separately from subsequent completions;
        preserve request generation so in-flight startup responses remain eligible
      → other session changes: clear old pending entries and invalidate old request generations
  Any app URLSession (default/ephemeral) now carries MockNetPackURLProtocol (swizzled at index 0)
  → canInit: httpCaptureGeneration != nil && http(s) && !skipHeader
  → startLoading:
        mock = MockRuleController.match(method, path)
        ── hit  → serve(mock:)   (no real network; record mocked=true entry)
        ── miss → forward via shared session (skipHeader stripped, body rebuilt)
                 → record(entry, generation:) on completion; reject responses belonging to discarded generations
  → record(): bodyParts() (1MB truncation; "[binary N bytes]" + base64 for binary)
              decodedBody() via codec slots (display only)
  → flush(): batch threshold 200 / 8MB / 2s → POST /api/v1/traffic
             failure → drop batch, no retry 

heartbeat says session == nil (idle) or stop()
  → updateSession(capturing: false) → startup/pending cleared; old HTTP request generation invalidated
  → stop() → unregister URLProtocol + uninstall swizzle

register/heartbeat permanently rejected (404, or register 403 with pairing token)
  → cancelStartupCapture(generation: captured before the request)
      → match generation and discard/invalidate startup requests atomically under the capture lock
      → a stale rejection cannot discard a newer startup buffer
```

### 3. Mock match & serve (three-tier body fallback)

```
URLProtocol.startLoading
  → MockRuleController.match(method.uppercased(), path) → MockResponse?
  → serve():
      headers = mock.headers ?? []; ensure Content-Type
      drop header keys containing "proto-res"  // stale key-rotation header must not leak
      body = bodyBase64 (raw bytes)          // ① unedited binary rule — replay exact bytes
           | encoder(bodyText, contentType)  // ② edited text → re-encode via codec
           | UTF-8 text                      // ③ plain text
      record TrafficEntry(mocked: true, matchedRuleId: <rule id>, request body captured for display)
      deliver HTTPURLResponse to the URLProtocol client
```

### 4. Binary codec pipeline 

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

### 5. Scan-connect 

```
Debug page → MockNetPackKit.connectByScan(from:completion:)
  → QRScannerViewController (AVCaptureSession; cameraDenied/unavailable → error)
  → QRConnectParser.parse(raw, expectedAppID: bundleID)
       appID mismatch → .appMismatch; bad payload → .invalidPayload
  → register POST /devices/register {app, did, pairingToken}   // token auto-register
       403 → .tokenInvalid (QR expired, refresh); other errors → .unreachable
  → success: ConnectionController.stop()            // switch, old server left to expire
      ServerAddressStore.save(newURL)
      ConnectionController.start(server: newURL, …) // direct connect now (A2)
Failure: saved address untouched (R1.6)

start(did:)  ( no-arg launch)
  → saved address? → start(server:, did:)   // direct connect, no scan needed (A2)
  → none         → startUnconfigured()      // resolves did only; .unconfigured, no network
did = externalDID (e.g. the business app's UIDevice.deviceID) ?? DIDStore — scan register reuses the SAME did 
```

## Fail-open guarantees

| Scenario | Behavior |
|---|---|
| Server unreachable at startup | No mocking or upload; configured startup forwards HTTP and keeps a bounded in-memory buffer while connection retries |
| Rule pull fails after a snapshot exists | Old snapshot kept and still applied |
| Capture session confirmed idle / startup unconfigured | `canInit` false — zero interception; startup buffer discarded on the first idle result |
| SDK own requests | `skipHeader` ⇒ never intercepted |
| Upload failure | Batch dropped; no retry, no local cache |
| Device not registered (404) | Silent stop of the loop; no popups, no retries; recover on app restart after Web registration |
