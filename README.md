# MockNetPackKit

MockNetPack's iOS debug SDK captures HTTP/HTTPS traffic inside the app, uploads it in batches, synchronizes device-scoped mock rules, and replays responses locally. No system proxy or capture certificate is required.

The repository version is **1.0.3**. It supports iOS 13+. `Package.swift` uses Swift tools 6.0 and declares macOS 12+ for local testing. The SDK has no third-party Swift package dependencies; QR scanning uses AVFoundation and gzip uses system zlib.

## Server and workflow

Server repository: [MockNetPackageServer](https://github.com/cx-z/MockNetPackageServer).

Use `server_address` as a placeholder for the deployed server's DNS name or IP address. The Web console is `http://server_address:4290/mocknetpack/`; the SDK API base URL is `http://server_address:4290/api/v1`. Use the actual external scheme and ports if the deployment exposes different URLs. The local project checkout is for development and testing.

1. Call `start()` early during app startup, before creating business URLSession instances.
2. Sign in to the Web console, select the app matching the Bundle ID, and generate a pairing QR code.
3. Scan from the app's debug screen. The SDK registers or reuses the device, saves the server address, and connects. Later launches reconnect without scanning again.
4. Activate the device's capture session in the Web console. Upload and mock execution require an active session. With a configured server, HTTP requests made before the first heartbeat are temporarily buffered to cover the cold-start handshake.
5. Create and enable rules in the Web console. Matching requests receive local responses; unmatched requests reach the real business server.

Rules are isolated by device and match **method + URL path**, ignoring the host, query string, and request body. A failed rule fetch retains the existing snapshot. Control-channel failures do not directly become business request errors; business network errors still propagate normally.

## Integration and Release isolation

The SDK does not decide Debug/Release integration itself. The host build configuration must ensure that **Release artifacts contain no SDK code or symbols**. Disabling SDK calls alone does not meet this requirement.

### CocoaPods

Add the pod to the business target for debug configurations only. Adjust configuration names to match your project:

```ruby
pod 'MockNetPackKit',
    :git => 'https://github.com/cx-z/MockNetPackKit.git',
    :tag => '1.0.3',
    :configurations => ['Debug']
```

Run `pod install` and open the `.xcworkspace`. Guard SDK imports and calls with the corresponding debug compilation condition.

### Swift Package Manager

Add `https://github.com/cx-z/MockNetPackKit.git` in Xcode, pin version `1.0.3`, and select product `MockNetPackKit`.

A normal SPM target dependency is not automatically Debug-only. Use a debug target or host build integration that excludes this product from Release linking. `#if DEBUG` guards calls, but does not by itself prove that the library is absent. Host CI should check Release Archive linkage and symbols.

## Startup and QR pairing

Call the SDK before initializing business network clients:

```swift
#if DEBUG
import MockNetPackKit

// Early app startup. With no saved address, this enters .unconfigured
// without contacting the server.
MockNetPackKit.start()
#endif
```

On the first unconfigured launch, the SDK pre-injects URLProtocol without intercepting business requests yet. If the host already has a stable device ID, use `MockNetPackKit.start(did: businessDeviceID)`. Startup and pairing use the same device identity.

From a UIViewController on the debug screen:

```swift
#if DEBUG
MockNetPackKit.connectByScan(from: self) { result in
    switch result {
    case .success:
        // Address saved and connection started; no additional start() needed.
        break
    case .failure(let error):
        print("MockNetPack pairing failed: \(error)")
    }
}
#endif
```

After pairing, call parameterless `start()` on later launches to reconnect. A failed scan does not overwrite the saved address. QR codes validate the app ID and expire after 10 minutes by default. For `appMismatch`, select the correct app; for `tokenInvalid`, refresh the QR code.

`start(server:appID:did:appVersion:logHandler:)` remains a public API for controlled testing or direct connection by an already registered device. It does not replace initial pairing. Business integrations should obtain and save the address through QR pairing.

## Permissions and network access

Provide the following in the host's debug configuration:

- `NSCameraUsageDescription`: explains camera access for QR scanning.
- `NSLocalNetworkUsageDescription`: explains local-network access when connecting to a test server on that network.
- For HTTP endpoints, configure ATS and network access for the actual debug domain / IP. The device must be able to reach the QR code's server address.

Use the deployed service address represented by `server_address`; verify device connectivity. Camera pairing requires a device with a working camera. `swift test` does not cover device permission prompts or the scanner UI.

## Public controls

| API | Purpose |
|---|---|
| `start(did:)` / `stop()` | Start or stop the connection; stopping preserves the device ID and saved address |
| `did` / `savedServerURL` | Inspect the device ID and saved server address |
| `connectionState` | `.unconfigured` / `.connecting` / `.connected` / `.offline` / `.tokenInvalid` |
| `sessionState` | `.idle` / `.capturing` |
| `onConnectionStateChange` / `onSessionStateChange` | State callbacks dispatched on the main thread |
| `resetServer()` | Clear the saved address; does not stop the current connection |
| `registerBinaryCodec(...)` | Register display and mock-replay codecs for private binary protocols |

To return to an unconfigured state, call `stop()`, `resetServer()`, then `start()`. Stopping does not delete the server-side device. If the device is deleted on the server, pair it again.

## Capture and replay boundaries

- Injection covers default / ephemeral URLSession configurations created after startup. It does not guarantee coverage of existing sessions, background URLSession, WKWebView, native sockets, or every third-party networking stack.
- Recorded request and response bodies have a 1 MiB truncation limit. Capture is not a complete network-packet archive. Failed upload batches are dropped without retry.
- SDK registration, heartbeat, upload, and other internal requests are excluded from recursive capture.
- With a configured server, startup HTTP traffic is forwarded immediately and held in memory until the first heartbeat confirms the session. The buffer keeps the earliest completed entries, up to 200 entries / 8 MiB of encoded traffic. The first active session detaches that buffer atomically and uploads it separately from subsequent completions. An idle response or `stop()` discards it; terminal registration/heartbeat rejection can discard only the startup generation that initiated the request. Late responses from a discarded capture generation are also excluded. This buffer is not persisted and does not retry failed uploads; unconfigured startup remains non-capturing.
- Binary replay uses this order: original `bodyBase64` bytes, edited text encoded by a registered codec, then UTF-8 text. The SDK can gzip before encryption; the host supplies decryption and corresponding decompression.
- Provide `requestDecrypt` and `responseDecrypt` separately when needed. Without a request decoder, the SDK does not substitute the response decoder.

## Repository and local testing

```text
MockNetPackKit/
├── Package.swift
├── MockNetPackKit.podspec
├── Sources/MockNetPackKit/             # 主 SDK：协议 + registry + 通用采集/连接/HTTP mock（纯注册制）
├── Sources/MockNetPackKitXCPush/       # XCPush 适配器（SwiftPM 独立 target MockNetPackKitXCPush）
├── Sources/MockNetPackKitXCPushObjC/   # XCPush ObjC 桥（DelegateProxy / InboxDecoder）
├── Sources/MockNetPackSmoke/
├── Tests/MockNetPackKitTests/
├── Tests/MockNetPackKitXCPushTests/
└── knowledgebase/
```

Run from the SDK repository root:

```bash
swift build
swift test
```

Module documentation is in [knowledgebase/overview.md](knowledgebase/overview.md), [architecture.md](knowledgebase/architecture.md), and [code-map.md](knowledgebase/code-map.md). The public API is defined in `Sources/MockNetPackKit/MockNetPackKit.swift`. Verify real-device capture, QR pairing, and Release isolation in the host project.

## Long-connection adapters (registration-only)

Long-connection capture and push mock are **adapter-based and registration-only**:
the SDK auto-registers **no** framework adapter.
An adapter probes the host process for a specific framework class
(`NSClassFromString`), installs a zero-intrusion proxy when the class is loaded,
and reports every long-connection event with an **adapter id** (shown in the Web
detail page as the "采集方式 / capture source" badge, e.g. `xcpush 适配器`).

### Current adapters

| Adapter | Framework probed | adapter id | channel id |
| --- | --- | --- | --- |
| `XCPushSocketAdapter` (in this pod / SwiftPM target `MockNetPackKitXCPush`) | FDSocketService `XCPushSocket` | `xcpush` | `xcpush_tcp` |

Adapters for SRWebSocket / Starscream / MQTT and other frameworks are not shipped
yet; the protocol is open for them (see "Writing an adapter" below).

### Integration (3 steps)

```ruby
# Podfile (Debug configuration only)
pod 'MockNetPackKit', :git => 'https://github.com/cx-z/MockNetPackKit.git',
    :tag => '1.0.3', :configurations => ['Debug']
```

```swift
import MockNetPackKit

// Once, before start():
MockNetPackKit.registerLongConnAdapter(XCPushSocketAdapter.self)
MockNetPackKit.start(did: UIDevice.deviceID)
```

That is the whole integration: **no framework-specific code in the host app**.
Without registration the long-connection capability stays silently disabled
(no crash, no error, observable via a fallback log entry).

### Registration semantics

- **Registration is the only way in.** An unregistered adapter is never probed
  or enabled.
- **Idempotent**: re-registering the same `adapterId` is ignored.
- **Multiple adapters coexist**: each adapter probes its own framework class and
  captures independently (channel id distinguishes the sources); probing order
  follows registration order.
- **Graceful fallback**: a registered adapter whose framework class is not
  loaded is skipped silently.
- **Push mock**: the XCPush adapter, once installed (Debug), also mounts the
  push-mock injector (`PushMockInjecting`) — no extra host wiring.

### Writing an adapter

Implement the public protocol `LongConnAdapter` (static requirements
`adapterId`, `channelId`, `probeClassNames`, `installIfNeeded()`) plus, for
push mock, `PushMockInjecting`; register via
`MockNetPackKit.registerLongConnAdapter(_:)`. Ship the adapter as a separate
SwiftPM target / pod that depends on `MockNetPackKit` (the main SDK never
depends on a concrete adapter).
