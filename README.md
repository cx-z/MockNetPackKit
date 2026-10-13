# MockNetPackKit

MockNetPack's iOS debug SDK captures HTTP/HTTPS traffic inside the app, uploads it in batches, synchronizes device-scoped mock rules, and replays responses locally. No system proxy or capture certificate is required.

The repository version is **1.0.3**. It supports iOS 13+. `Package.swift` uses Swift tools 6.0 and declares macOS 12+ for local testing. The SDK has no third-party Swift package dependencies; QR scanning uses AVFoundation and gzip uses system zlib.

## Server and workflow

Server repository: [MockNetPackageServer](https://github.com/cx-z/MockNetPackageServer).

Use `server_address` as a placeholder for the deployed server's DNS name or IP address. The Web console is `http://server_address:4290/mocknetpack/`; the SDK API base URL is `http://server_address:4290/api/v1`. Use the actual external scheme and ports if the deployment exposes different URLs. The local project checkout is for development and testing.

1. Call `start()` early during app startup, before creating business URLSession instances.
2. Sign in to the Web console, select the app matching the Bundle ID, and generate a pairing QR code.
3. Scan from the app's debug screen. The SDK registers or reuses the device, saves the server address, and connects. Later launches reconnect without scanning again.
4. Activate the device's capture session in the Web console. Capture and mock execution begin only while the session is active.
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
- Binary replay uses this order: original `bodyBase64` bytes, edited text encoded by a registered codec, then UTF-8 text. The SDK can gzip before encryption; the host supplies decryption and corresponding decompression.
- Provide `requestDecrypt` and `responseDecrypt` separately when needed. Without a request decoder, the SDK does not substitute the response decoder.

## Repository and local testing

```text
MockNetPackKit/
├── Package.swift
├── MockNetPackKit.podspec
├── Sources/MockNetPackKit/
├── Sources/MockNetPackSmoke/
├── Tests/MockNetPackKitTests/
└── knowledgebase/
```

Run from the SDK repository root:

```bash
swift build
swift test
```

Module documentation is in [knowledgebase/overview.md](knowledgebase/overview.md), [architecture.md](knowledgebase/architecture.md), and [code-map.md](knowledgebase/code-map.md). The public API is defined in `Sources/MockNetPackKit/MockNetPackKit.swift`. Verify real-device capture, QR pairing, and Release isolation in the host project.
