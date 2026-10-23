import Foundation
import os

/// 本地 Mock 规则控制器：持有当前生效规则快照，供 URLProtocol 匹配回包。
///
/// 语义（fail-open）：
/// - 快照来自心跳后按 `rulesVersion` 增量拉取 `GET .../mock-rules?sinceVersion=`。
///   仅服务端 `effective=true` 的规则会被下发并参与匹配。
/// - 匹配键 = Method + URL 路径（不含 Query/Body）；不区分 host。
/// - **fail-open**：从未拉到快照时拉取失败 → 不 Mock，走真实网络；
///   已有快照后本次拉取失败 → 沿用旧快照继续 Mock。
/// - **iOS-AN9 快照持久化**：同步成功的快照落盘（MockRuleSnapshotStore）；冷启动懒加载，
///   使启动握手期（规则下载前）的业务请求也能命中上次同步的快照。
/// - **iOS-AN9 断连保护**：连接失败达阈值 / 永久拒绝时 `clearSnapshot()` 清空内存+磁盘，
///   连接恢复后以 sinceVersion=0 重新从服务端下载（旧快照不恢复）。
/// - 规则跨会话保留；URLProtocol 的接管判定跟随门闩（capturing 或 启动缓冲），
///   idle 时本控制器即便有快照也不会被询问。
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

    /// 持久化 Store：默认 .standard；测试注入独立 defaults suite 隔离。
    /// 对齐安卓 `snapshotStore`（可注入禁用持久化——iOS Store 构造恒成功，单测用独立 suite）。
    internal var snapshotStore: MockRuleSnapshotStore = MockRuleSnapshotStore()

    /// 是否已尝试过磁盘加载（幂等，进程内仅一次；reset() 后重置，同进程
    /// stop→start 可重新从磁盘加载，对齐冷启动语义）。
    private var loaded = false

    // MARK: - 快照加载与持久化（iOS-AN9）

    /// 首次使用前从磁盘加载快照（幂等；失败则保持空快照，不 Mock）。
    /// 整个 加载→解析→赋值 在锁内完成：与 `clearSnapshot()`（同锁）互斥，
    /// 杜绝「加载读到了旧磁盘、clear 已清内存、随后又写回」的复活竞态。
    /// 磁盘读/清为一次性懒加载路径（冷启动早期无并发），UserDefaults 同步内存
    /// 访问毫秒级，锁内可接受（对齐安卓 ensureLoaded 语义与 D2 硬化）。
    /// 注意（安卓踩坑 a）：必须先持有 store 引用再 load——磁盘为空时若跳过
    /// store 持有，后续 apply() 的 save 会静默无操作 → 快照永不落盘。
    private func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        let store = snapshotStore // 先持有 store（后续 apply 落盘依赖该引用）
        if let snapshot = store.load() {
            localVersion = snapshot.version
            rules = snapshot.rules
            SDKLog.info("rules snapshot loaded version=\(snapshot.version) active=\(snapshot.rules.count)", category: "mock")
        }
        // 损坏快照：store.load() 解码失败时已清坏文件并返回 nil → 保持空快照，
        // 下次同步可正常重写磁盘（对齐安卓 F5：坏快照不永久禁用持久化）。
    }

    /// 断连保护：清空内存 + 磁盘快照（连接失败达阈值 / 永久拒绝时调用）。
    /// 清空后 match 必返回 nil → 不再 Mock；连接恢复后 syncIfNeeded 以
    /// sinceVersion=0 重新从服务端下载全量规则（用户决策：旧快照不恢复）。
    /// 内存 + 磁盘清除均持锁：与 ensureLoaded（锁内加载+赋值）互斥，杜绝
    /// 「清内存后、清磁盘前」窗口内读回旧盘导致规则复活（安卓 D2 硬化）。
    /// UserDefaults 同步内存访问毫秒级，且 clearSnapshot 仅断连保护/永久拒绝
    /// 低频路径调用，锁内可接受。
    internal func clearSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        localVersion = 0
        rules = []
        snapshotStore.clear()
    }

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
    /// 入口 ensureLoaded：磁盘已有快照时，冷启动首心跳后按磁盘版本增量拉取
    /// （版本一致 no-op，避免无谓全量拉取）。
    private func pendingPullVersion(serverVersion: Int) -> Int? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        guard serverVersion != localVersion else { return nil }
        return localVersion
    }

    /// 拉取成功后更新快照（锁内更新 + 锁外持久化）。
    private func apply(list: MockRuleList) {
        lock.lock()
        localVersion = list.version
        rules = list.rules
        lock.unlock()
        // 锁外持久化（磁盘 IO）：snapshotStore 在 ensureLoaded 时已持有。
        // 与 clearSnapshot 的竞态窗口经分析无实质危害：apply 由心跳成功路径驱动、
        // countRegisterFailure 由心跳失败路径驱动，二者在连接层串行队列（inflight
        // 互斥）上不可能同一时刻并发；且 apply 写的是「新同步规则」而非旧快照复活
        // （与安卓一致，D2 硬化未改 apply 锁外 save）。
        snapshotStore.save(MockRuleSnapshotStore.Snapshot(version: list.version, rules: list.rules))
    }

    // MARK: - 匹配

    /// 按 Method + URL 路径查找本地生效规则；无匹配返回 nil（走真实网络）。
    /// 命中时把规则 ID 写入 response.ruleId，随命中流量上报 matchedRuleId。
    /// 入口 ensureLoaded：冷启动首次 match 前先加载磁盘快照。
    func match(method: String, path: String) -> MockResponse? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        let m = method.uppercased()
        for r in rules where r.method.uppercased() == m && r.path == path {
            var resp = r.response
            resp.ruleId = r.id
            return resp
        }
        return nil
    }

    /// 清空本地快照（连接层 stop 时调用；did 保留，下次会话重新拉取）。
    /// 磁盘快照保留（下次冷启动仍可启动期 Mock）；`loaded=false` 使同进程
    /// stop→start 后首次 match/syncIfNeeded 重新从磁盘加载（对齐冷启动语义）。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        localVersion = 0
        rules = []
        loaded = false
    }
}
