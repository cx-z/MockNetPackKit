import Foundation
import os

/// 本地 push mock 规则控制器（能力线 L7）：持有当前生效 push 规则快照，
/// 供注入器（PushMockInjecting，由适配器模块挂载）在业务消费前执行替换。
///
/// 语义（对齐 MockRuleController 模式 + 技术方案 3.2/3.4 + 决策 D1）：
/// - 快照来自心跳后按 `pushRulesVersion` 增量拉取
///   `GET .../push-mock-rules?sinceVersion=`。仅服务端 `effective=true` 的
///   规则会被下发并参与匹配。
/// - 匹配键 = channelId（必选）+ bizType（可选）+ payload 轻量条件
///   （最多 1 条 JSONPath + 1 个子串，决策 D1）。
/// - **fail-open A**：从未拉到快照时拉取失败 → 不 Mock，原样放行；
///   已有快照后本次拉取失败 → 沿用旧快照继续 Mock。
/// - 规则跨会话保留，但仅在代理层拦截钩子启用（Debug-only）且规则
///   effective=true 时执行。
/// - 注入器（L6.1a 重做）：由适配器模块在安装成功后挂载
///   `PushMockInjecting` 实现；未挂载 → 指令跳过待下次心跳（fail-open）。
public final class PushMockRuleController: @unchecked Sendable {

    /// 进程内共享实例。
    public static let shared = PushMockRuleController()

    /// 注入器（框架特定实现；适配器模块安装成功后经 PushMockInjecting 协议
    /// 挂载；未挂载时模拟推送指令跳过保留待重试）。锁保护。
    public var mockInjector: PushMockInjecting? {
        get { lock.lock(); defer { lock.unlock() }; return mockInjectorValue }
        set { lock.lock(); defer { lock.unlock() }; mockInjectorValue = newValue }
    }
    private var mockInjectorValue: PushMockInjecting?

    // MARK: - 测试注入点

    /// 直接写入快照（测试用，绕过网络拉取）。
    func applyForTesting(rules: [PushMockRule], version: Int) {
        lock.lock()
        defer { lock.unlock() }
        localVersion = version
        self.rules = rules
    }

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    /// 本地已生效快照对应的服务端 push 规则版本。
    private var localVersion = 0
    private var rules: [PushMockRule] = []

    // MARK: - 增量拉取

    /// 心跳成功后调用：服务端 push 版本与本地不一致时增量拉取，否则 no-op。
    /// 拉取失败按 fail-open A 处理（保留旧快照）。
    func syncIfNeeded(client: ConnectionClient, app: String, did: String, serverVersion: Int) async {
        let fromVersion = pendingPullVersion(serverVersion: serverVersion)
        guard let since = fromVersion else { return }

        do {
            let list: PushMockRuleList = try await client.get(
                "devices/\(app)/\(did)/push-mock-rules?sinceVersion=\(since)",
                as: PushMockRuleList.self)
            apply(list: list)
            SDKLog.info("push rules synced version=\(list.version) active=\(list.rules.count)", category: "mock")
        } catch {
            // fail-open A：拉取失败，沿用旧快照（首次失败则本地仍为空，即不 Mock）。
            SDKLog.error("push rules pull failed: \(error.localizedDescription); keeping snapshot", category: "mock")
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
    private func apply(list: PushMockRuleList) {
        lock.lock()
        defer { lock.unlock() }
        localVersion = list.version
        rules = list.rules
    }

    // MARK: - L7.2b 模拟推送：指令注入 + ack 回报

    /// 心跳成功后调用：对心跳响应携带的 pending 指令逐条构造假 Packet 并注入
    /// 到当前活跃长连接；注入成功 → ack 回报服务端（指令消费）；注入失败
    /// （无活跃连接 / Packet 构造失败）→ 不 ack，指令保留待下次心跳重试。
    /// 注入/回报失败均不阻塞心跳周期（fail-open）。注入器未挂载（无适配器
    /// 安装）→ 指令跳过保留，待下次心跳（L6.1a 重做注册制语义）。
    func injectPendingCommands(client: ConnectionClient, app: String, did: String,
                               commands: [PushRuleCommand]) async {
        guard !commands.isEmpty else { return }
        guard let injector = mockInjector else {
            SDKLog.info("push mock injector unavailable, commands deferred commandCount=\(commands.count)", category: "mock")
            return
        }
        var acked: [String] = []
        for command in commands {
            guard let packet = injector.makePacket(command: command) else {
                SDKLog.error("push mock makePacket failed command=\(command.id), retry next heartbeat", category: "mock")
                continue
            }
            guard injector.inject(packet: packet) else {
                // 无活跃长连接：保留指令，下次心跳重试。
                SDKLog.error("push mock inject skipped command=\(command.id) (no active socket), retry next heartbeat", category: "mock")
                continue
            }
            acked.append(command.id)
            SDKLog.info("push mock injected command=\(command.id) rule=\(command.ruleId) msgId=\(String(describing: injector.recentInjections(limit: 1).first?.msgId))", category: "mock")
        }
        guard !acked.isEmpty else { return }
        await ackCommands(client: client, app: app, did: did, ids: acked)
    }

    /// 上报指令消费（POST push-rule-commands/ack；失败仅记日志——指令已注入，
    /// 重复下发由服务端幂等/过期清理兜底）。
    private func ackCommands(client: ConnectionClient, app: String, did: String, ids: [String]) async {
        do {
            struct AckBody: Encodable { let ids: [String] }
            try await client.postNoContent(
                "devices/\(app)/\(did)/push-rule-commands/ack",
                body: AckBody(ids: ids))
            SDKLog.info("push mock ack reported ids=\(ids)", category: "mock")
        } catch {
            SDKLog.error("push mock ack failed: \(error.localizedDescription); command may re-deliver", category: "mock")
        }
    }

    // MARK: - 匹配查询（供拦截器）

    /// 按 channelId+bizType 返回本地生效规则（effective=true；bizType 空规则
    /// 匹配任意 bizType——匹配键 channelId 必选 + bizType 可选）。
    /// 实时拦截器随后对 payload 做轻量条件匹配（决策 D1：最多 1 条 JSONPath
    /// + 1 个子串）。
    func activeRules(channelId: String, bizType: String) -> [PushMockRule] {
        lock.lock()
        defer { lock.unlock() }
        return rules.filter { rule in
            rule.effective && rule.channelId == channelId &&
                (rule.bizType.isEmpty || rule.bizType == bizType)
        }
    }

    /// 清空本地快照（连接层 stop 时调用；下次会话重新拉取）。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        localVersion = 0
        rules = []
    }
}
