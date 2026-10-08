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
                       DESC
  s.homepage         = 'https://github.com/cx-z/mockd'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'MockNetPack' => 'dev@mocknetpack.local' }
  s.source           = { :git => 'https://github.com/cx-z/MockNetPackKit.git', :tag => '1.0.3' }
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/MockNetPackKit/**/*.{swift}'
  s.frameworks       = 'Foundation', 'AVFoundation'   #  扫码连接（AVCaptureSession）
  s.libraries        = 'z'   #  registerBinaryCodec 内置 gzip（zlib deflate）
end
