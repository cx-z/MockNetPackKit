Pod::Spec.new do |s|
  s.name             = 'MockNetPackKit'
  s.version          = '1.0.4'
  s.summary          = 'MockNetPack iOS SDK. HTTP capture & remote mock, integrated by the host app.'
  s.description      = <<-DESC
MockNetPackKit is the client SDK for the internal HTTP capture & Mock platform.
It includes the connection layer (device registration, heartbeat, session state),
a URLProtocol interceptor for capturing HTTP traffic, a local mock client, and
the LongConnHook declarative long-connection capture/push-mock layer.
Whether to integrate (and in which build configurations) is decided by the
host app; the integrating app links this pod in Debug configuration only.

L6.5 (2026-10-16, decision D-L6.5): this pod is DECLARATION-ONLY and contains
ZERO framework-specific code. Long-connection capture & push mock are enabled by
a <=20-line LongConnHook.register(_:) declaration (probe class name, hook
points, payload extraction and injection closures are supplied by the host).
No adapter for any specific push framework is shipped or auto-registered.
                       DESC
  s.homepage         = 'https://github.com/cx-z/mockd'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'MockNetPack' => 'dev@mocknetpack.local' }
  s.source           = { :git => 'https://github.com/cx-z/MockNetPackKit.git', :tag => '1.0.4' }
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'

  # 声明制（D-L6.5 方案 A）：仅主 SDK 源码（无任何框架适配器/ObjC 桥）。
  s.source_files     = 'Sources/MockNetPackKit/**/*.{swift}'
  s.frameworks       = 'Foundation', 'AVFoundation'   #  扫码连接（AVCaptureSession）
  s.libraries        = 'z'   #  registerBinaryCodec 内置 gzip（zlib deflate）
end
