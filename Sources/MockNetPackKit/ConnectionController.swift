import Foundation
import os

/// 连接层控制器：设备注册、心跳循环、断线重连、会话状态推导。
///
/// 设计要点：
/// - 全部可变状态由 `lock` 保护；调度在专用串行队列上串行执行，
///   同一时刻至多一个注册/心跳在途（`inflight` 标志）。
/// - 心跳间隔以服务端下发 `serverConfig.heartbeatIntervalSeconds` 为准
///   （4.12 起钳制 2...300，仅作防误配保护；契约实际下发 capturing 3s /
///   idle 5s——3s 必须放行，否则"快速感知规则变更"被抬成 5s），
///   心跳失败按指数退避重试。
/// - 心跳 404（device_not_registered）→ M7.2.3 起 SDK 不再自动注册：
///   设备必须先在 Web 手动注册。收到 404 后静默停循环（不弹窗、不重试），
///   仅写一行技术日志；业务方重启 App 后若 Web 已注册则自动恢复。
/// - 注册 403（携带配对令牌时，4.13）→ 令牌无效/过期：停循环并上抛
///   `.tokenInvalid` 可展示状态（「二维码已过期，请刷新」），不再退避重试。
/// - 60s 超时语义由服务端判定（契约 §2）：SDK 恢复心跳后自然收到
///   `session=null`，无需自实现超时计时。
/// - 本类不实现 Debug/Release 门（M0 责任边界：由业务方构建层保证）。
final class ConnectionController: @unchecked Sendable {

    /// 进程内共享实例（业务方经 `MockNetPackKit` 门面访问）。
    static let shared = ConnectionController()

    // MARK: - 测试注入点

    /// 客户端工厂：测试注入 MockURLProtocol 的 session 配置。
    var clientFactory: (@Sendable (URL) -> ConnectionClient)?
    /// 覆盖服务端下发的心跳间隔（秒）；测试用（0.1~0.5s 加速验证）。
    var heartbeatIntervalOverride: TimeInterval?
    /// 初始退避基数（秒）；测试可调小。
    var backoffBase: TimeInterval = 1

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.mocknetpack.connection", qos: .utility)

    private var isRunningValue = false
    /// 连接代次：start/stop 时递增。在途注册/心跳的 await 返回后先校验代次
    /// （4.7），旧代结果直接丢弃——防止 stop() 后旧心跳把连接状态"翻活"。
    private var generationValue = 0
    private var serverURL: URL?
    private var appIDValue: String?
    private var appVersionValue: String?
    private var appNameValue: String?
    private var sdkVersionValue: String = ""
    private var osVersionValue: String = ""
    private var didValue: String?
    private var logHandler: (@Sendable (String) -> Void)?

    // M9.2 扫码连接：本次连接会话使用的配对令牌与设备显示名（一次性注册通道；
    // 连接会话内保留——网络抖动重注册时仍可复用，stop/start 时重置）。
    private var pairingTokenValue: String?
    private var deviceNameValue: String?

    private var serverConfig = ServerConfig(heartbeatIntervalSeconds: 5, heartbeatTimeoutSeconds: 60)
    private var registered = false
    /// M7.2.3: 设备未在 Web 注册（register/heartbeat 404）→ 静默停循环，不再重试。
    private var unregistered = false
    private var currentBackoff: TimeInterval = 1
    private var inflight = false

    private var connectionStateValue: ConnectionState = .offline
    private var sessionStateValue: SessionState = .idle

    // MARK: - 对外回调（主线程派发）

    var onSessionStateChange: (@Sendable (SessionState) -> Void)?
    var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)?

    // MARK: - 生命周期

    /// 启动连接层（幂等：已在运行则直接返回）。did 首次生成后持久化。
    /// - Parameters:
    ///   - server: 服务器 base URL。
    ///   - pairingToken: 扫码配对令牌（M9.2，可选）：随注册请求携带，服务端据此自动注册/复用设备。
    ///   - deviceName: 扫码自动注册时的设备显示名（M9.2，可选）。
    func start(server: URL,
               appID: String?,
               externalDID: String? = nil,
               appVersion: String?,
               appName: String? = nil,
               sdkVersion: String,
               osVersion: String,
               pairingToken: String? = nil,
               deviceName: String? = nil,
               logHandler: (@Sendable (String) -> Void)? = nil) {
        lock.lock()
        guard !isRunningValue else { lock.unlock(); return }
        isRunningValue = true
        generationValue &+= 1
        serverURL = server
        appIDValue = appID
        appVersionValue = appVersion
        appNameValue = appName
        sdkVersionValue = sdkVersion
        osVersionValue = osVersion
        // M7.2.4: 业务方传入 did（如 IntegratingApp Keychain deviceID）则直接用；否则 SDK 自行生成。
        didValue = externalDID ?? DIDStore.did(forApp: appID ?? "")
        self.logHandler = logHandler
        serverConfig = ServerConfig(heartbeatIntervalSeconds: 5, heartbeatTimeoutSeconds: 60)
        registered = false
        unregistered = false
        currentBackoff = backoffBase
        pairingTokenValue = pairingToken
        deviceNameValue = deviceName
        lock.unlock()

        log("MockNetPackKit connecting to \(server.absoluteString) app=\(appID ?? "?") did=\(self.did ?? "?")")
        setConnectionState(.connecting)
        scheduleNext()

        // M2.4：启动流量采集（注册全局 URLProtocol；会话未激活时不拦截）。
        TrafficCaptureController.shared.start(
            serverURL: server,
            appID: appID ?? "",
            did: self.did ?? "",
            logHandler: self.logHandler)
    }

    /// 无服务器启动（M9.2）：仅解析 did 并置 `.unconfigured`，不发起网络、不启动采集。
    /// 供 `start()` 无参门面在未保存地址时调用——保证后续扫码复用同一 did（D7：
    /// 扫码注册与启动注册使用同一设备标识，不因扫码新生成）。
    func startUnconfigured(appID: String?,
                           externalDID: String? = nil,
                           appVersion: String?,
                           appName: String? = nil,
                           sdkVersion: String,
                           osVersion: String,
                           logHandler: (@Sendable (String) -> Void)? = nil) {
        lock.lock()
        guard !isRunningValue else { lock.unlock(); return }
        isRunningValue = true
        generationValue &+= 1
        serverURL = nil
        appIDValue = appID
        appVersionValue = appVersion
        appNameValue = appName
        sdkVersionValue = sdkVersion
        osVersionValue = osVersion
        didValue = externalDID ?? DIDStore.did(forApp: appID ?? "")
        self.logHandler = logHandler
        pairingTokenValue = nil
        deviceNameValue = nil
        registered = false
        unregistered = false
        lock.unlock()

        log("MockNetPackKit unconfigured: no saved server address (scan to connect)")
        setConnectionState(.unconfigured)
    }

    /// 停止连接层：停调度、清状态（did 保留，下次 start 复用）。
    func stop() {
        lock.lock()
        guard isRunningValue else { lock.unlock(); return }
        isRunningValue = false
        generationValue &+= 1   // 作废所有在途循环，旧代结果不得再应用
        inflight = false
        pairingTokenValue = nil
        deviceNameValue = nil
        lock.unlock()
        log("MockNetPackKit stopped")
        // M2.4：先停止采集（注销 URLProtocol、清空待上传批次），再广播 idle 状态。
        TrafficCaptureController.shared.stop()
        MockRuleController.shared.reset()
        setConnectionState(.offline)
        setSessionState(.idle)
    }

    // MARK: - 对外只读状态

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunningValue
    }

    var did: String? {
        lock.lock(); defer { lock.unlock() }
        return didValue
    }

    /// 当前连接会话的 appID（M9.2：扫码流程复用与启动一致的 appID/did 作用域）。
    var resolvedAppID: String? {
        lock.lock(); defer { lock.unlock() }
        return appIDValue
    }

    var connectionState: ConnectionState {
        lock.lock(); defer { lock.unlock() }
        return connectionStateValue
    }

    var sessionState: SessionState {
        lock.lock(); defer { lock.unlock() }
        return sessionStateValue
    }

    // MARK: - 调度（串行队列）

    /// 在串行队列上调度下一轮注册/心跳；`now` 为 true 时立即执行。
    private func scheduleNext(now: Bool = false, delay: TimeInterval? = nil) {
        let block: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.runIfIdle()
        }
        if now {
            queue.async(execute: block)
        } else {
            queue.asyncAfter(deadline: .now() + (delay ?? 0), execute: block)
        }
    }

    /// 若无在途任务则开启一轮注册/心跳。捕获当前代次，在途结果只属于该代。
    private func runIfIdle() {
        lock.lock()
        guard isRunningValue, !inflight, !unregistered else { lock.unlock(); return }
        inflight = true
        let gen = generationValue
        lock.unlock()

        let task = Task { [weak self] in
            await self?.performCycle(gen: gen)
        }
        _ = task
    }

    /// 单轮：注册（若未注册）→ 心跳 → 处理结果并调度下一轮。
    private func performCycle(gen: Int) async {
        let info = withLock { () -> (running: Bool, serverURL: URL?, appID: String?, did: String?) in
            (isRunningValue, serverURL, appIDValue, didValue)
        }
        guard info.running, let serverURL = info.serverURL, let appID = info.appID, let did = info.did else {
            finishCycle(gen: gen)
            return
        }

        let client = makeClient(serverURL: serverURL)

        // 1) 需要注册：未注册过（或上次心跳 404 置为未注册）。
        let needRegister = withLock { !registered }
        if needRegister {
            await performRegister(client: client, appID: appID, did: did, gen: gen)
            return  // performRegister 内已调度下一轮
        }

        // 2) 心跳。
        let result = await heartbeat(client: client, appID: appID, did: did)
        // 4.7：await 返回后校验代次——stop() 可能已发生，旧结果不得回翻状态。
        guard isCurrent(gen) else {
            finishCycle(gen: gen)
            return
        }
        switch result {
        case .success(let resp):
            withLock {
                currentBackoff = backoffBase
                registered = true
                serverConfig = resp.serverConfig
            }
            setConnectionState(.connected)
            // M2.4：先驱动流量采集启停，再广播会话状态——外部 onSessionStateChange
            // 回调可能立即发起业务请求，此时采集开关必须已就绪（否则首批请求漏采）。
            TrafficCaptureController.shared.updateSession(
                capturing: resp.session != nil,
                sessionID: resp.session?.id)
            setSessionState(resp.session != nil ? .capturing : .idle)
            // M3.4：按服务端 rulesVersion 增量拉取本地 Mock 快照（fail-open）。
            await MockRuleController.shared.syncIfNeeded(
                client: client, app: appID, did: did,
                serverVersion: resp.rulesVersion ?? 0)
            finishCycle(gen: gen)
            scheduleNext(delay: heartbeatInterval())

        case .failure(let error):
            switch error {
            case ConnectionClientError.httpStatus(404):
                // 设备未在 Web 注册（或被删除）→ 静默停循环，不自动重试。
                // 用户需在 Web 重新注册后重启 App 恢复连接。
                withLock {
                    registered = false
                    unregistered = true
                }
                setConnectionState(.offline)
                log("heartbeat 404: device not registered; SDK idle (re-register in Web and restart App)")
                finishCycle(gen: gen)

            default:
                // 网络错误 / 5xx / 解码失败 → 指数退避重连。
                let backoff = advanceBackoff()
                setConnectionState(.offline)
                log("heartbeat failed: \(error.localizedDescription); retrying in \(Int(backoff))s")
                finishCycle(gen: gen)
                scheduleNext(delay: backoff)
            }
        }
    }

    // MARK: - 注册

    private func performRegister(client: ConnectionClient, appID: String, did: String, gen: Int) async {
        let meta = withLock { () -> (os: String, sdk: String, app: String, appName: String?, token: String?, deviceName: String?) in
            (osVersionValue, sdkVersionValue, appVersionValue ?? "", appNameValue, pairingTokenValue, deviceNameValue)
        }
        let req = RegisterDeviceRequest(
            app: appID,
            did: did,
            platform: "ios",
            osVersion: meta.os,
            sdkVersion: meta.sdk,
            appVersion: meta.app,
            appName: meta.appName,
            pairingToken: meta.token,
            deviceName: meta.deviceName
        )
        do {
            let resp: RegisterDeviceResponse = try await client.post(
                "devices/register", body: req, as: RegisterDeviceResponse.self)
            // 4.7：代次校验，旧代注册结果直接丢弃。
            guard isCurrent(gen) else {
                finishCycle(gen: gen)
                return
            }
            withLock {
                registered = true
                serverConfig = resp.serverConfig
            }
            log("registered app=\(appID) did=\(did)")
            setConnectionState(.connected)
            finishCycle(gen: gen)
            // M8.2：register 成功后立即心跳（去掉原 2s 硬延迟）。
            // 启动链路 register(RTT1)→heartbeat(RTT2)→rules sync(RTT3) 串行，
            // LAN 下 ~1s 内完成启动连接与规则同步。
            scheduleNext(now: true)
        } catch ConnectionClientError.httpStatus(404) {
            // M7.2.3: 服务端拒绝注册（设备未在 Web 手动注册）→ 静默停循环。
            guard isCurrent(gen) else {
                finishCycle(gen: gen)
                return
            }
            withLock {
                registered = false
                unregistered = true
            }
            setConnectionState(.offline)
            log("register 404: device not registered on server; SDK idle (register the device in Web)")
            finishCycle(gen: gen)
            // 不 scheduleNext。
        } catch ConnectionClientError.httpStatus(let code) {
            guard isCurrent(gen) else {
                finishCycle(gen: gen)
                return
            }
            // 4.13：携带配对令牌注册收到 403（pairing_token_invalid）→ 令牌无效/
            // 过期（二维码已失效）。停连并上抛可展示状态，不再无限退避重连——
            // 重试同一枚过期令牌永远只会再拿到 403；业务方应提示「二维码已过期，
            // 请刷新」。未携带令牌时的 403 保持原有退避语义。
            if code == 403 {
                let hasToken = withLock { pairingTokenValue != nil }
                if hasToken {
                    withLock {
                        registered = false
                        unregistered = true
                    }
                    setConnectionState(.tokenInvalid)
                    log("register 403: pairing token invalid or expired; SDK idle (re-scan a fresh QR)")
                    finishCycle(gen: gen)
                    return  // 不 scheduleNext。
                }
            }
            let backoff = advanceBackoff()
            setConnectionState(.offline)
            log("register httpStatus=\(code); retrying in \(Int(backoff))s")
            finishCycle(gen: gen)
            scheduleNext(delay: backoff)
        } catch {
            guard isCurrent(gen) else {
                finishCycle(gen: gen)
                return
            }
            let backoff = advanceBackoff()
            setConnectionState(.offline)
            log("register failed: \(error.localizedDescription); retrying in \(Int(backoff))s")
            finishCycle(gen: gen)
            scheduleNext(delay: backoff)
        }
    }

    // MARK: - 心跳

    private func heartbeat(client: ConnectionClient, appID: String, did: String) async -> Result<HeartbeatResponse, Error> {
        let sdk = withLock { sdkVersionValue }
        do {
            let resp: HeartbeatResponse = try await client.post(
                "devices/\(appID)/\(did)/heartbeat",
                body: HeartbeatRequest(sdkVersion: sdk),
                as: HeartbeatResponse.self)
            return .success(resp)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 辅助

    private func makeClient(serverURL: URL) -> ConnectionClient {
        if let factory = clientFactory {
            return factory(serverURL)
        }
        return ConnectionClient(baseURL: serverURL)
    }

    private func heartbeatInterval() -> TimeInterval {
        if let override = heartbeatIntervalOverride { return override }
        let seconds = withLock { serverConfig.heartbeatIntervalSeconds }
        // 4.12：下限 2s（原 5s 会把服务端契约的 capturing 3s 抬成 5s，令
        // "快速感知规则变更"失效）。2s 仍是防误配保护：服务端异常下发 <2s
        // 时不会被照单全收打爆网络。
        return TimeInterval(min(max(seconds, 2), 300))
    }

    /// 返回本次退避时长并翻倍（上限 30s）。
    private func advanceBackoff() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let b = currentBackoff
        currentBackoff = min(b * 2, 30)
        return b
    }

    /// 结束一轮循环；仅当代次仍为当前代时才清 inflight（4.7：stop→start
    /// 快速切换后，旧在途循环不得清掉新一轮的 inflight 标志）。
    private func finishCycle(gen: Int) {
        lock.lock()
        if generationValue == gen {
            inflight = false
        }
        lock.unlock()
    }

    /// 4.7：报告 gen 是否仍是当前连接代次（stop 后即为 false，旧代结果丢弃）。
    private func isCurrent(_ gen: Int) -> Bool {
        withLock { isRunningValue && generationValue == gen }
    }

    private func setConnectionState(_ state: ConnectionState) {
        let changed: Bool = withLock { () -> Bool in
            guard connectionStateValue != state else { return false }
            connectionStateValue = state
            return true
        }
        guard changed else { return }
        let handler = withLock { onConnectionStateChange }
        DispatchQueue.main.async {
            handler?(state)
        }
    }

    private func setSessionState(_ state: SessionState) {
        let changed: Bool = withLock { () -> Bool in
            guard sessionStateValue != state else { return false }
            sessionStateValue = state
            return true
        }
        guard changed else { return }
        let handler = withLock { onSessionStateChange }
        DispatchQueue.main.async {
            handler?(state)
        }
    }

    private func log(_ message: String) {
        let handler = withLock { logHandler }
        handler?(message)
        Logger(subsystem: "com.mocknetpack.kit", category: "connection").info("\(message, privacy: .public)")
    }
}

// MARK: - 锁工具（内部）

private extension ConnectionController {
    /// 加锁执行闭包并返回结果。
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
