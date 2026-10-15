//
//  LongConnAdapter.swift
//  MockNetPackKit
//
//  L6.1a：长连接框架适配器协议（能力线 L6 适配器 registry 化）。
//
//  背景：通用 SDK 不应内置某个具体 push 框架的类名/方法签名（用户拍板：
//  moox/Dokimo 能用仅是恰好共用 FDSocketService——这是架构侵入）。L6 把
//  「探测 → 安装」抽象为适配器：每个适配器封装一个具体长连接框架的零侵入
//  接入（NSClassFromString 探测 + hook/swizzle 安装），registry 按注册顺序
//  探测进程内已加载的框架，命中即自动启用对应适配器（见 LongConnAdapterRegistry）。
//
//  语言决策（2026-10-15 用户拍板 D-L6.1）：Swift 协议 + Swift registry。
//  适配器多为无实例逻辑的 enum/final class（如 XCPushSocketAdapter）；需要
//  ObjC 兜底（forwardInvocation 代理）的部分保持在各适配器自己的 proxy 层，
//  不 @objc 化本协议。
//

import Foundation

/// 长连接框架适配器（L6.1a）。
///
/// 每个适配器声明：
/// - `adapterId`：适配器标识（L6.2 采集标注用，Web 展示能力来源，如 "xcpush"）；
/// - `channelId`：归属的长连接通道标识（与 LongConnectionRecordInput.channelId
///   一致，多框架共存区分维度，如 "xcpush_tcp"）；
/// - `probeClassNames`：探测目标类名列表（NSClassFromString，任一命中即视为
///   该框架已加载）；
/// - `installIfNeeded()`：安装 hook（幂等），返回是否安装成功（启用）。
///
/// 多适配器共存（决策 D-L6.3）：不同框架同时存在时各自启用、各自采集，由
/// channelId 区分；未命中已知框架时返回 false，registry 静默跳过（不崩溃、
/// 不报错，L6.1b 优雅回退）。
public protocol LongConnAdapter {
    /// 适配器标识（采集标注用，如 "xcpush"；L6.2 Web 展示能力来源）。
    static var adapterId: String { get }
    /// 归属的长连接通道标识（与记录 channelId 一致，多框架共存区分维度）。
    static var channelId: String { get }
    /// 探测目标类名列表（NSClassFromString；任一命中即视为框架已加载）。
    static var probeClassNames: [String] { get }
    /// 安装适配器（幂等）：探测类存在则执行 hook/swizzle 安装。
    /// - Returns: 是否安装成功（启用）；框架未加载 → false（registry 静默跳过）。
    static func installIfNeeded() -> Bool
}
