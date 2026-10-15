Pod::Spec.new do |s|
  s.name             = 'MockNetPackKit'
  s.version          = '1.0.3'
  s.summary          = 'MockNetPack iOS SDK. HTTP capture & remote mock, integrated by the host app.'
  s.description      = <<-DESC
MockNetPackKit is the client SDK for the internal HTTP capture & Mock platform.
It includes the connection layer (device registration, heartbeat, session state),
a URLProtocol interceptor for capturing HTTP traffic, and a local mock client.
Whether to integrate (and in which build configurations) is decided by the
host app; the integrating app links this pod in Debug configuration only.

L6.1a rework (2026-10-15, decision D-L6.4): this pod is REGISTRATION-ONLY for
long-connection adapters — no adapter is auto-registered. The XCPush adapter
sources (SocketAdapter/Recorder/MockInterceptor/ChannelCoder + ObjC bridge)
are compiled into this pod (single module); the host app explicitly registers
XCPushSocketAdapter via MockNetPackKit.registerLongConnAdapter(_:) — that one
line is the only way to enable long-connection capture & push mock. Adapters
for other frameworks will be added the same way (registration-only).
NOTE: a CocoaPods subspec cannot be an independent module (module_name is
root-only) and cannot depend on its parent spec, so under
generate_multiple_pod_projects the XCPush code stays in this single module.
SwiftPM keeps a separate target MockNetPackKitXCPush (see Package.swift).
                       DESC
  s.homepage         = 'https://github.com/cx-z/mockd'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'MockNetPack' => 'dev@mocknetpack.local' }
  s.source           = { :git => 'https://github.com/cx-z/MockNetPackKit.git', :tag => '1.0.3' }
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'

  # 纯注册制（D-L6.4）：单 pod 单 module（CocoaPods 限制下 subspec 无法独立
  # module）。XCPush 源码编入本 pod，但注册制强制显式 registerLongConnAdapter
  # 才启用；不注册 → 长连接能力静默未启用。
  s.source_files     = 'Sources/MockNetPackKit/**/*.{swift}',
                       'Sources/MockNetPackKitXCPush/**/*.{swift}',
                       'Sources/MockNetPackKitXCPushObjC/**/*.{h,m}'
  s.public_header_files = 'Sources/MockNetPackKitXCPushObjC/include/*.h'
  s.frameworks       = 'Foundation', 'AVFoundation'   #  扫码连接（AVCaptureSession）
  s.libraries        = 'z'   #  registerBinaryCodec 内置 gzip（zlib deflate）；XCPush 采集解压
end
