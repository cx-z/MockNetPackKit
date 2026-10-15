//
//  PushMockInjecting.swift
//  MockNetPackKit
//
//  L6.1a 重做（2026-10-15 决策 D-L6.4 全注册制）：push mock 注入器协议。
//
//  背景：L7 模拟推送的「构造假 Packet + 注入长连接」是框架特定的（XCPush
//  的 Packet protobuf 类、注入路径）。独立适配器模块拆分后，主 SDK 的
//  PushMockRuleController（通用指令调度）不能反向依赖具体框架实现，因此
//  注入能力经本协议解耦——适配器模块实现协议，并在适配器安装成功后把实现
//  挂到 PushMockRuleController.mockInjector。
//
//  现状（决策 D-L6.3）：mock 注入仍只有 XCPush 一个实现；多框架接入时
//  按 channelId 定位注入器（留待第二适配器接入再解）。
//

import Foundation

/// push mock 注入能力（框架特定实现，由适配器模块提供；L7 模拟推送）。
public protocol PushMockInjecting: AnyObject {

    /// 由 pending 指令构造假 Packet（模板 payload + 新 msgId）；
    /// 类不可用 / 字段写入失败 → nil（指令保留待下次心跳重试）。
    /// - Parameter command: 服务端下发的一次性模拟推送指令。
    /// - Returns: 构造成功的假 Packet 对象，失败为 nil。
    func makePacket(command: PushRuleCommand) -> AnyObject?

    /// 将假 Packet 注入当前活跃长连接（走代理完整转发链）。
    /// - Parameter packet: makePacket 返回的假 Packet。
    /// - Returns: 是否注入成功（无活跃连接 → false，指令保留重试）。
    func inject(packet: AnyObject) -> Bool

    /// 最近注入记录（调试/测试断言）。
    /// - Parameter limit: 最多返回条数。
    func recentInjections(limit: Int) -> [(msgId: UInt64, bizType: String, ruleId: String)]
}
