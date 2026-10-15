Pod::Spec.new do |s|
  s.name             = 'MockNetPackKitXCPush'
  s.version          = '1.0.0'
  s.summary          = 'MockNetPack XCPush long-connection adapter. Probe & capture FDSocketService XCPushSocket, register with MockNetPackKit.'
  s.description      = <<-DESC
MockNetPackKitXCPush is the XCPush (FDSocketService) long-connection adapter for
the MockNetPack iOS SDK. Split out of the main SDK as an independent module
(L6.1a rework, 2026-10-15, decision D-L6.4): the main SDK ships no concrete
framework adapter; the host app links this pod and explicitly registers
XCPushSocketAdapter via MockNetPackKit.registerLongConnAdapter(_:).

Contains: XCPushSocketAdapter (setDelegate:/connectToHost:onPort: swizzle +
XCAsyncSocketDelegate forwarding), XCPushLongConnRecorder (capture), L7
push-mock interceptor (PushMockInjecting), XCPushChannelCoder, and the ObjC
bridge (XCPushDelegateProxy / XCPushInboxDecoder).
                       DESC
  s.homepage         = 'https://github.com/cx-z/mockd'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'MockNetPack' => 'dev@mocknetpack.local' }
  s.source           = { :git => 'https://github.com/cx-z/MockNetPackKit.git', :tag => '1.0.0' }
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Sources/MockNetPackKitXCPush/**/*.{swift}', 'Sources/MockNetPackKitXCPushObjC/**/*.{h,m}'
  s.public_header_files = 'Sources/MockNetPackKitXCPushObjC/include/*.h'
  s.dependency 'MockNetPackKit'
  s.libraries        = 'z'   #  L5.2 XCPush 采集 zipType=1 解压（Gzip.gunzip）
end
