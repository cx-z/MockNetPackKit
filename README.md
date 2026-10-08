# MockNetPackKit

MockNetPack's iOS Debug SDK — an in-app HTTP capture/upload and remote-mock client.

> Current version 1.0.3, containing the connection layer (registration/heartbeat/session state), the URLProtocol interceptor, and the mock client.
> No third-party code dependencies upstream; the server lives in `server/`.

## Integration approach: decided by the integrating app, the SDK does not self-control

This SDK **does not make Debug/Release decisions itself, nor does it enforce any isolation policy** — whether to integrate, and in which configuration, is entirely up to the integrating business app.

The requirement on the integrator is: **the Release artifact must not contain this SDK's code/symbols** (must be "not carried", not merely "not active"). This requirement is guaranteed by the integrating app's build integration layer, not implemented inside the SDK. The recommended approach is in the SDK integration guide under `tasks/`; the essentials are:

1. All business-side calls to `MockNetPackKit` are wrapped in `#if DEBUG` (zero references to this library after a Release build);
2. After packaging, the integrator verifies that the Release Archive contains no symbols from this library (enforced in CI).

## Package structure

```
MockNetPackKit/
├── Package.swift
├── Sources/MockNetPackKit/     # product implementation
└── Tests/MockNetPackKitTests/
```

## Local verification

```bash
cd iOS/MockNetPackKit
swift build          # build
swift test           # run tests
```

## Integration with a CocoaPods project

The integration test project uses CocoaPods (`use_frameworks! :linkage => :static` + modular_headers). The coexistence evaluation and recommended approach are in the SDK integration guide under `tasks/`.
