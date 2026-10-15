//
//  LongConnAdapterRegistry.swift
//  MockNetPackKit
//
//  L6.1a + L6.1a 重做（2026-10-15 决策 D-L6.4 全注册制）：长连接框架适配器注册表。
//
//  职责：登记适配器（**纯注册制——不内置任何框架适配器**，决策 D-L6.4）、
//  NSClassFromString 探测进程内已加载的长连接框架、启用命中的适配器。
//  安装点 = MockNetPackKit start 路径（ConnectionController.start /
//  startUnconfigured 调 installAllIfNeeded），幂等可重复调用。
//
//  语义（决策 D-L6.3 多适配器共存）：按注册顺序逐适配器探测，各适配器独立
//  启用（框架同时存在则同时采集，channelId 区分）；全部未命中 → 静默跳过
//  （L6.1b 优雅回退：不崩溃、不报错、业务无感，仅汇总日志可观测）。
//  接入方显式 register（唯一接入方式）；未注册任何适配器 → 长连接能力
//  静默未启用（回退日志可观测）。
//
//  实现注记：注册时一次性提取 adapterId 并捕获安装闭包（条目结构承载），
//  不在存储/遍历路径上做「存在类型元类型 + 键路径访问静态协议需求」——
//  Swift 6.3 编译器在该模式下 SILGen 崩溃（实测 signal 5，LongConnAdapterRegistry
//  enabledAdapterIds 键路径触发）。
//

import Foundation

/// 长连接框架适配器注册表（单例；锁保护，Swift 6 并发安全）。
final class LongConnAdapterRegistry: @unchecked Sendable {

    /// 进程内共享实例（注册表初始为空——纯注册制，决策 D-L6.4）。
    static let shared = LongConnAdapterRegistry()

    /// 注册条目：注册时提取元信息 + 捕获安装闭包（规避静态协议需求经
    /// 存在类型元类型访问的编译器崩溃，见文件头注记）。
    private struct AdapterEntry: @unchecked Sendable {
        let adapterId: String
        let install: () -> Bool
    }

    /// 探测结果日志出口（L6.1b 优雅回退可观测；默认 SDKLog.info，
    /// 测试注入 fake 记录——仿 XCPushLongConnRecorder.recordSink 模式）。
    var logSink: (String) -> Void = { SDKLog.info($0, category: "longconn") }

    private let lock = NSLock()
    /// 已注册适配器条目（按注册顺序探测）。
    private var entriesValue: [AdapterEntry] = []
    /// 已启用（探测命中且安装成功）的适配器 ID。
    private var enabledValue: Set<String> = []

    private init() {}

    /// 注册一个长连接框架适配器（幂等：同 adapterId 重复注册忽略；
    /// 后续探测按注册顺序进行）。
    /// - Parameter adapter: 适配器类型（实现 LongConnAdapter）。
    func register(_ adapter: LongConnAdapter.Type) {
        lock.lock()
        defer { lock.unlock() }
        let id = adapter.adapterId
        guard !entriesValue.contains(where: { $0.adapterId == id }) else { return }
        entriesValue.append(AdapterEntry(adapterId: id, install: { adapter.installIfNeeded() }))
    }

    /// 探测并启用所有「已注册且未启用」的适配器（幂等，可多次调用；
    /// 安装点 = ConnectionController.start / startUnconfigured）。
    /// 安装调用在锁外执行（适配器 install 内部自持锁，避免嵌套锁；
    /// 期间新注册的适配器由下次调用接管）。
    /// 探测结果汇总日志（L6.1b）：本次有探测动作且全部未命中 → 输出
    /// 「no known framework detected」摘要（含已探测 adapterId）；有启用 →
    /// 输出启用清单。全部已启用（无 pending）→ 不输出（幂等不重复）。
    func installAllIfNeeded() {
        let pending: [AdapterEntry]
        lock.lock()
        pending = entriesValue.filter { !enabledValue.contains($0.adapterId) }
        lock.unlock()
        guard !pending.isEmpty else { return }

        var newlyEnabled: [String] = []
        for entry in pending {
            if entry.install() {
                lock.lock()
                enabledValue.insert(entry.adapterId)
                lock.unlock()
                newlyEnabled.append(entry.adapterId)
            }
        }

        if newlyEnabled.isEmpty {
            let probed = pending.map(\.adapterId).joined(separator: ", ")
            logSink("longconn adapter registry: no known framework detected (probed: \(probed)), adapters skipped")
        } else {
            let enabled = newlyEnabled.joined(separator: ", ")
            logSink("longconn adapter registry: adapters enabled (\(enabled))")
        }
    }

    /// 已启用适配器 ID 列表（健康检查/测试；保持注册顺序）。
    var enabledAdapterIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entriesValue.filter { enabledValue.contains($0.adapterId) }.map(\.adapterId)
    }

    /// 全部已注册适配器 ID 列表（测试/诊断；保持注册顺序）。
    var registeredAdapterIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entriesValue.map(\.adapterId)
    }

    /// 清空注册表（测试用；勿在生产路径调用。纯注册制下初始为空，
    /// 无需重新注册内置适配器）。
    func resetForTesting() {
        lock.lock()
        entriesValue.removeAll()
        enabledValue.removeAll()
        lock.unlock()
    }
}
