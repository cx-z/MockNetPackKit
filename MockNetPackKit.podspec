Pod::Spec.new do |s|
  s.name             = 'MockNetPackKit'
  s.version          = '0.2.0-m5'
  s.summary          = 'MockNetPack iOS SDK. HTTP capture & remote mock, integrated by the host app.'
  s.description      = <<-DESC
MockNetPackKit is the client SDK for the internal HTTP capture & Mock platform.
M1.5: connection layer (did registration, heartbeat, session state); interceptor
lands in M2, mock client in M3.
Whether to integrate (and in which build configurations) is decided by the
host app; Knocknock links this pod in Debug configuration only.
                       DESC
  s.homepage         = 'https://github.com/cx-z/mockd'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'MockNetPack' => 'dev@mocknetpack.local' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/MockNetPackKit/**/*.{swift}'
  s.frameworks       = 'Foundation'
end
