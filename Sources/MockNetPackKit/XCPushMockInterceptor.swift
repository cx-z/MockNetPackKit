//
//  XCPushMockInterceptor.swift
//  MockNetPackKit
//
//  L5.3：XCPush push mock 拦截钩子（Debug-only，为 L7 预留）。
//
//  机制（技术方案 3.2）：代理层在业务分发前升级为"拦截者"——
//    socket → XCPushSocket 解帧 → Packet → 代理层
//      ├─ 规则查询（channelId+bizType+payload 匹配，命中与否）
//      ├─ 命中：替换 Packet.bizData（可写字段）+ 必要时生成新 msgId
//      └─ 未命中：原样放行
//    → 转发给原 delegate（业务侧无感）→ 同时旁路采集日志
//
//  本文件 = 钩子本体：规则查询闭包（L7 接入服务端下推规则）+ 替换/放行动作。
//  范围纪律：不做 L7 完整规则体系（匹配/下发/Web 一键建规则均不实现）。
//
//  替换只改数据层（bizData / msgId），不重建整包，避免破坏 type/clientId
//  等协议状态；新 msgId 规避 KK vReceivedMessageIds 判重丢弃（技术方案 3.3#1），
//  且自然进入采集去重表（采集在拦截之后，读到的是替换后值，与业务一致）。
//

import Foundation

#if DEBUG

/// XCPush push mock 拦截器（单例；Debug-only，Release 构建零残留）。
final class XCPushMockInterceptor: @unchecked Sendable {

    static let shared = XCPushMockInterceptor()

    /// 规则查询闭包（L7 由服务端下推规则接入；测试注入）。
    /// - Parameters:
    ///   - channelId: 通道标识（当前固定 "xcpush_tcp"）。
    ///   - bizType: 包业务类型（数字枚举，原始值）。
    ///   - msgId: 包消息 ID。
    ///   - payload: 原始 bizData（未解压；未命中语义由规则侧决定）。
    /// - Returns: 决策；`nil` = 未命中，原样放行。
    typealias RuleProvider = (_ channelId: String, _ bizType: Int32,
                              _ msgId: UInt64, _ payload: Data?) -> MockDecision?
    var ruleProvider: RuleProvider?

    private let lock = NSLock()

    /// 命中替换决策。
    enum MockDecision {
        /// 替换业务数据；`newMsgId` 非 nil 时同步改 msgId（规避判重丢弃）。
        case replace(payload: Data, newMsgId: UInt64?)
    }

    /// 对收包执行拦截（在采集/转发之前调用；无规则或未命中 → 不改任何字段）。
    /// - Parameter talk: Packet 实例（KVC 可写字段 bizData/msgId）。
    func intercept(talk: AnyObject) {
        guard let provider = ruleProvider else { return }
        let decision = withLock { provider(Self.channelId, kvBizType(talk), kvMsgId(talk), kvBizData(talk)) }
        guard let decision else { return }
        switch decision {
        case .replace(let payload, let newMsgId):
            setKv("bizData", talk, payload)
            if let newMsgId {
                setKv("msgId", talk, NSNumber(value: newMsgId))
            }
        }
    }

    private static let channelId = "xcpush_tcp"

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - KVC 读写（防御：先 responds 再操作；真实 Packet 字段为 ObjC 属性）

    private func kv(_ key: String, from obj: AnyObject) -> Any? {
        guard obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key)
    }

    private func kvBizType(_ talk: AnyObject) -> Int32 {
        (kv("bizType", from: talk) as? NSNumber)?.int32Value ?? 0
    }

    private func kvMsgId(_ talk: AnyObject) -> UInt64 {
        (kv("msgId", from: talk) as? NSNumber)?.uint64Value ?? 0
    }

    private func kvBizData(_ talk: AnyObject) -> Data? {
        kv("bizData", from: talk) as? Data
    }

    /// KVC 写字段；setter 不存在（如裸 NSObject）则 no-op（防御）。
    private func setKv(_ key: String, _ obj: AnyObject, _ value: Any) {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard obj.responds(to: NSSelectorFromString(setter)) else { return }
        obj.setValue(value, forKey: key)
    }
}

#endif
