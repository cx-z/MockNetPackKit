import Foundation
import os

/// 流量采集控制器（M2.4）：攒批、上传、启停。
///
/// 职责：
/// - 跟随抓包会话启停：`updateSession(capturing:sessionID:)` 由连接层心跳结果
///   驱动——capturing 时注册拦截生效并采集，idle 时停止并清空待上传批次
///   （会话结束本地未上传的临时记录一并丢弃，与服务端"临时记录随会话清空"一致）。
/// - 攒批上传：按条数阈值（200）/字节阈值（8MB）/定时（2s）触发，
///   单批 ≤500 条（契约）；上传失败直接丢弃批次、不重传（需求 F7.6）。
/// - 全局注册/注销 `MockNetPackURLProtocol`（决策 D-M2-2）。
final class TrafficCaptureController: @unchecked Sendable {

    /// 进程内共享实例。
    static let shared = TrafficCaptureController()

    // MARK: - 测试注入点

    /// 上传客户端工厂：测试注入 MockURLProtocol 的 session 配置。
    var clientFactory: (@Sendable (URL) -> ConnectionClient)?
    /// 攒批定时触发间隔（秒）。
    var flushInterval: TimeInterval = 2

    // MARK: - 攒批阈值

    /// 单批条数阈值（≤500 契约上限，留余量）。
    let maxBatchCount = 200
    /// 单批字节阈值（避免超服务端 10MB 请求体上限）。
    let maxBatchBytes = 8 * 1024 * 1024

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.mocknetpack.capture", qos: .utility)

    private var running = false
    private var capturingValue = false
    private var sessionIDValue: String?
    private var appIDValue: String?
    private var didValue: String?
    private var serverURLValue: URL?
    private var logHandler: (@Sendable (String) -> Void)?

    /// App 注入的响应体解码器（M4）；由 MockNetPackKit.setBodyDecoder 设置，
    /// URLProtocol 在组装真实响应时读取。独立小锁保护（设置低频、读取高频）。
    private let decoderLock = NSLock()
    private var bodyDecoderValue: MockNetPackKit.BodyDecoder?
    var bodyDecoder: MockNetPackKit.BodyDecoder? {
        get { decoderLock.lock(); defer { decoderLock.unlock() }; return bodyDecoderValue }
        set { decoderLock.lock(); bodyDecoderValue = newValue; decoderLock.unlock() }
    }
    private var pending: [TrafficEntry] = []
    private var pendingBytes = 0

    // MARK: - 生命周期

    /// 启动采集（连接层 start 时调用；幂等）。注册全局 URLProtocol。
    func start(serverURL: URL, appID: String, did: String, logHandler: (@Sendable (String) -> Void)? = nil) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        serverURLValue = serverURL
        appIDValue = appID
        didValue = did
        self.logHandler = logHandler
        pending = []
        pendingBytes = 0
        lock.unlock()

        // 注入：swizzle URLSessionConfiguration 类构造方法（默认/临时会话携带拦截器），
        // 并注册全局类（NSURLConnection 时代兜底）。会话未激活时 canInit 返回 false。
        URLSessionConfigurationInjector.install()
        URLProtocol.registerClass(MockNetPackURLProtocol.self)
        scheduleFlush()
        log("traffic capture started (URLProtocol injected)")
    }

    /// 停止采集（连接层 stop 时调用）：注销拦截器、清空状态与待上传批次。
    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        capturingValue = false
        sessionIDValue = nil
        pending = []
        pendingBytes = 0
        lock.unlock()

        // 还原注入、注销全局类；已创建会话的拦截由 canInit 静态开关兜底（stop 后 false）。
        URLSessionConfigurationInjector.uninstall()
        URLProtocol.unregisterClass(MockNetPackURLProtocol.self)
        log("traffic capture stopped")
    }

    /// 会话状态更新（连接层心跳结果驱动）。
    /// - Parameters:
    ///   - capturing: 服务端是否存在激活会话。
    ///   - sessionID: 激活会话 ID（capturing 时必传；idle 时传 nil）。
    func updateSession(capturing: Bool, sessionID: String?) {
        lock.lock()
        guard running else { lock.unlock(); return }
        let changed = capturingValue != capturing || sessionIDValue != sessionID
        capturingValue = capturing
        sessionIDValue = sessionID
        // 会话切换（开始/结束）都清空待上传批次：
        // - 开始：上个会话的残留批次与新会话无关；
        // - 结束：临时记录随会话结束丢弃（与服务端清空语义一致）。
        pending = []
        pendingBytes = 0
        lock.unlock()

        guard changed else { return }
        log(capturing ? "capture session active (\(sessionID ?? "?"))" : "capture session idle; pending cleared")
        if capturing { flush() }
    }

    /// 当前是否处于抓包中（URLProtocol.canInit 读取；锁保护）。
    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return running && capturingValue
    }

    // MARK: - 采集与攒批

    /// 记录一条完整请求/响应（由 MockNetPackURLProtocol 调用）。
    func record(_ entry: TrafficEntry) {
        lock.lock()
        guard running, capturingValue else { lock.unlock(); return }
        let bytes = entry.requestBody.utf8.count + (entry.responseBody?.utf8.count ?? 0) + 256
        pending.append(entry)
        pendingBytes += bytes
        let count = pending.count
        let tooMany = count >= maxBatchCount
        let tooBig = pendingBytes >= maxBatchBytes
        lock.unlock()

        if tooMany || tooBig {
            flush()
        }
    }

    /// 立即上传待上传批次（定时/阈值/会话激活时调用；无数据或无会话则 no-op）。
    func flush() {
        let batch: [TrafficEntry]
        let sessionID: String
        let serverURL: URL
        let appID: String
        let did: String
        lock.lock()
        guard capturingValue,
              let sid = sessionIDValue,
              let url = serverURLValue,
              let app = appIDValue,
              let d = didValue,
              !pending.isEmpty else {
            lock.unlock()
            return
        }
        batch = pending
        sessionID = sid
        serverURL = url
        appID = app
        did = d
        pending = []
        pendingBytes = 0
        lock.unlock()

        let client = makeClient(serverURL: serverURL)
        let req = TrafficUploadRequest(app: appID, did: did, sessionId: sessionID, entries: batch)
        Task { [weak self] in
            do {
                let _: TrafficUploadResponse = try await client.post("traffic", body: req, as: TrafficUploadResponse.self)
                self?.log("uploaded \(batch.count) traffic entries")
            } catch {
                // 需求 F7.6：不做本地缓存、不重传；失败批次直接丢弃。
                self?.log("traffic upload failed: \(error.localizedDescription); batch dropped (no retry)")
            }
        }
    }

    // MARK: - 辅助

    private func scheduleFlush() {
        queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self else { return }
            self.flush()
            let stillRunning = self.withLock { self.running }
            if stillRunning {
                self.scheduleFlush()
            }
        }
    }

    private func makeClient(serverURL: URL) -> ConnectionClient {
        if let factory = clientFactory {
            return factory(serverURL)
        }
        return ConnectionClient(baseURL: serverURL)
    }

    private func log(_ message: String) {
        let handler = withLock { logHandler }
        handler?(message)
        Logger(subsystem: "com.mocknetpack.kit", category: "capture").info("\(message, privacy: .public)")
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
