Pod::Spec.new do |s|
  s.name             = 'MockNetPackKit'
  s.version          = '1.0.1'
  s.summary          = 'MockNetPack iOS SDK. HTTP capture & remote mock, integrated by the host app.'
  s.description      = <<-DESC
MockNetPackKit is the client SDK for the internal HTTP capture & Mock platform.
M1.5: connection layer (did registration, heartbeat, session state); interceptor
lands in M2, mock client in M3.
Whether to integrate (and in which build configurations) is decided by the
host app; the integrating app links this pod in Debug configuration only.
                       DESC
  s.homepage         = 'https://github.com/cx-z/mockd'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'MockNetPack' => 'dev@mocknetpack.local' }
  s.source           = { :git => 'https://github.com/cx-z/MockNetPackKit.git', :tag => '1.0.0' }
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/MockNetPackKit/**/*.{swift}'
  s.frameworks       = 'Foundation', 'AVFoundation'   # M9.2 扫码连接（AVCaptureSession）
  s.libraries        = 'z'   # M6.1 registerBinaryCodec 内置 gzip（zlib deflate）
end
