//
//  XCPushChannelCoder.swift
//  MockNetPackKit
//
//  L5.6：XCPush 通道内置 coder（零侵入自动注册——业务侧无需再注册解码能力）。
//  动态解 protobuf（ObjC 侧 NSClassFromString("Sync")，不链接 FDSocketService）；
//  解不出返回 nil，SDK 自动降级 base64。
//

import Foundation
#if canImport(MockNetPackKitObjC)
import MockNetPackKitObjC
#else
import MockNetPackKit
#endif

/// XCPush 通道编解码器（channelId = "xcpush_tcp"）。
/// 与一期业务侧 coder 语义一致：Sync protobuf → bussdata(data 子字典) → pretty JSON；
/// 非 protobuf 包回退 JSON 直解；均失败返回 nil（降级 base64）。
struct XCPushChannelCoder: MockNetPackChannelCoder {
    func decode(channelId: String, raw: Data, context: [String: String]) -> String? {
        // 注意：函数体不能用 #if canImport(MockNetPackKitObjC) 包裹——
        // CocoaPods 是单模块，无此 module → canImport=false 会永远 return nil（真机 bug，
        // SwiftPM 测试环境有此 target 所以单测测不出来）。ObjC 符号在 pod 集成态经
        // umbrella header 直接可见（与 adapter 里 XCPushDelegateProxy 同一模式）。
        let out = MNPXCPushDecodeToJSON(raw)
        SDKLog.info("coder decode channel=\(channelId) rawLen=\(raw.count) -> \(out == nil ? "nil(降级base64)" : "text(\(out!.count))")",
                    category: "longconn")
        return out
    }
}
