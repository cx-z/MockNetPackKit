import Foundation
import os

/// 本地 Mock 规则控制器（M3.4）：持有当前生效规则快照，供 URLProtocol 匹配回包。
///
/// 语义（需求 6.5/6.6 + 决策 E1/fail-open A）：
/// - 快照来自心跳后按 `rulesVersion` 增量拉取 `GET .../mock-rules?sinceVersion=`。
///   仅服务端 `effective=true` 的规则会被下发并参与匹配。
/// - 匹配键 = Method + URL 路径（不含 Query/Body）；不区分 host。
/// - **fail-open A**：从未拉到快照时拉取失败 → 不 Mock，走真实网络；
///   已有快照后本次拉取失败 → 沿用旧快照继续 Mock。
/// - 规则跨会话保留，但仅在抓包会话 capturing 期间生效——
///   URLProtocol.canInit 跟随会话开关，idle 时本控制器即便有快照也不会被询问。
final class MockRuleController: @unchecked Sendable {

    /// 进程内共享实例。
    static let shared = MockRuleController()

    // MARK: - 测试注入点

    /// 直接写入快照（测试用，绕过网络拉取）。
    func applyForTesting(rules: [MockRule], version: Int) {
        lock.lock()
        defer { lock.unlock() }
        localVersion = version
        self.rules = rules
    }

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    /// 本地已生效快照对应的服务端规则版本。
    private var localVersion = 0
    private var rules: [MockRule] = []

    // MARK: - 增量拉取

    /// 心跳成功后调用：服务端版本与本地不一致时增量拉取，否则 no-op。
    /// 拉取失败按 fail-open A 处理（保留旧快照）。
    func syncIfNeeded(client: ConnectionClient, app: String, did: String, serverVersion: Int) async {
        let fromVersion = pendingPullVersion(serverVersion: serverVersion)
        guard let since = fromVersion else { return }

        do {
            let list: MockRuleList = try await client.get(
                "devices/\(app)/\(did)/mock-rules?sinceVersion=\(since)",
                as: MockRuleList.self)
            apply(list: list)
            SDKLog.info("rules synced version=\(list.version) active=\(list.rules.count)", category: "mock")
        } catch {
            // fail-open A：拉取失败，沿用旧快照（首次失败则本地仍为空，即不 Mock）。
            SDKLog.error("rules pull failed: \(error.localizedDescription); keeping snapshot", category: "mock")
        }
    }

    /// 返回需要拉取时的 sinceVersion；版本一致返回 nil（不调用 async 加锁）。
    private func pendingPullVersion(serverVersion: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard serverVersion != localVersion else { return nil }
        return localVersion
    }

    /// 拉取成功后更新快照（同步加锁）。
    private func apply(list: MockRuleList) {
        lock.lock()
        defer { lock.unlock() }
        localVersion = list.version
        rules = list.rules
    }

    // MARK: - 匹配

    /// 按 Method + URL 路径查找本地生效规则；无匹配返回 nil（走真实网络）。
    func match(method: String, path: String) -> MockResponse? {
        lock.lock()
        defer { lock.unlock() }
        let m = method.uppercased()
        for r in rules where r.method.uppercased() == m && r.path == path {
            return r.response
        }
        return nil
    }

    /// 清空本地快照（连接层 stop 时调用；did 保留，下次会话重新拉取）。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        localVersion = 0
        rules = []
    }
}
