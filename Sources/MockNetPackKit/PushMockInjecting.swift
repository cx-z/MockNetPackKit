//
//  PushMockInjecting.swift
//  MockNetPackKit
//
//  push mock 注入能力协议。
//
//  背景：模拟推送的「构造假消息 + 注入长连接」是框架特定的（消息格式、
//  投递路径由各框架协议决定）。主 SDK 的 PushMockRuleController（通用指令
//  调度）不依赖任何具体框架实现，注入能力经本协议解耦——接入方（或
//   LongConnHook 声明中的 injector 闭包）实现协议，并在安装成功后挂到
//  PushMockRuleController.mockInjector。
//
//  形态：**一步注入**——业务侧「构造 + 投递」合并为
//  `inject(command:)`，返回是否投递成功（无活跃连接 → false，指令保留
//  待下次心跳重试）。框架特有协议逻辑由业务方自己的工具提供（LongConnHook
//  声明的 injector 闭包一行调用），公开仓库零框架痕迹。
//

import Foundation

/// push mock 注入能力（框架特定实现，由接入方/声明闭包提供；模拟推送）。
public protocol PushMockInjecting: AnyObject {

    /// 由 pending 指令构造假消息并投递到当前活跃长连接（一步完成）；
    /// 构造失败 / 无活跃连接 → false（指令保留待下次心跳重试）。
    /// - Parameter command: 服务端下发的一次性模拟推送指令。
    /// - Returns: 是否投递成功。
    func inject(command: PushRuleCommand) -> Bool

    /// 最近注入记录（调试/测试断言）。
    /// - Parameter limit: 最多返回条数。
    func recentInjections(limit: Int) -> [(msgId: UInt64, bizType: String, ruleId: String)]
}
