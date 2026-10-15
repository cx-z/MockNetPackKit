import Foundation
import os

/// 流量采集控制器：攒批、上传、启停。
///
/// 职责：
/// - 跟随抓包会话启停：`updateSession(capturing:sessionID:)` 由连接层心跳结果
///   驱动——capturing 时注册拦截生效并采集，idle 时停止并清空待上传批次
///   （会话结束本地未上传的临时记录一并丢弃，与服务端"临时记录随会话清空"一致）。
/// - 攒批上传：按条数阈值（200）/字节阈值（8MB）/定时（2s）触发，
///   单批 ≤500 条（契约）；上传失败直接丢弃批次、不重传（需求 ）。
/// - 全局注册/注销 `MockNetPackURLProtocol`（决策 D-）。
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

    // MARK: - 长连接阈值（能力线 L1；独立额度，不占用 HTTP 流量额度）

    /// 长连接独立额度（默认 1000 条，可注入便于测试）；超限丢最旧（rolling window）。
    var maxLongConnEntries = 1000
    /// 长连接 payload 完整保留上限（10KB，决策 #2）；超限仅存预览。
    let maxLongConnPayloadBytes = 10 * 1024
    /// 长连接 payload 预览上限（1KB，残留小项默认值）。
    let maxLongConnPreviewBytes = 1024
    /// 长连接单批条数阈值（≤500 契约上限，与 HTTP 同留余量 200）。
    let maxLongConnBatchCount = 200
    /// 长连接单批字节阈值（避免超服务端 10MB 请求体上限）。
    let maxLongConnBatchBytes = 8 * 1024 * 1024
    /// snapshot 30s 兜底（决策 #3）：距上次 snapshot 上报超过该时长且存在缓存
    /// 快照时，随下一批次补发一条（状态变化立即上报由业务侧注入保证）。
    /// var 可注入便于单测（默认 30s）。
    var longConnSnapshotFallbackInterval: TimeInterval = 30

    // MARK: - 状态（锁保护）

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.mocknetpack.capture", qos: .utility)
    /// L4：长连接 raw packet 解码专用串行队列（保证多包顺序与收包一致，不阻塞 socket 接收线程）。
    private let decodeQueue = DispatchQueue(label: "com.mocknetpack.longconn.decode", qos: .utility)

    private var running = false
    private var capturingValue = false
    /// URLProtocol 注入是否已安装（arm/start 共用，锁保护）：启动早期已由 arm()
    /// 预注入时，start() 不再重复 install/registerClass，避免重复注册同一拦截器类。
    private var injectedValue = false
    private var sessionIDValue: String?
    private var appIDValue: String?
    private var didValue: String?
    private var serverURLValue: URL?
    private var logHandler: (@Sendable (String) -> Void)?

    // MARK: - 长连接状态（能力线 L1；与 HTTP 流量缓冲互不干扰）

    /// 长连接待上传缓冲（独立于 traffic pending；独立额度、独立上报端点）。
    private var longConnPending: [LongConnectionRecordInput] = []
    private var longConnPendingBytes = 0
    /// 长连接采集开关（默认开；关闭后仅丢弃、不影响业务侧打点）。
    private var longConnEnabledValue = true
    /// 最近一次业务注入的 snapshot 记录（30s 兜底补发源）。
    private var longConnLastSnapshot: LongConnectionRecordInput?
    /// 最近一次 snapshot 上报时间（兜底判定；nil = 从未上报）。
    private var longConnLastSnapshotAt: Date?

    // MARK: - 长连接双路径去重（L5.5）

    /// 注入/代理双路径去重窗口表（key = "\(channelId)|\(msgId)" → 最近入队时间）。
    /// 注入模式（L4 业务桥接）与代理模式（L5 自动采集）并存时，同一通道同一包会在
    /// 毫秒级内各上报一次：窗口内重复直接丢弃；窗口外重复（服务端真实重发）保持
    /// 代理层 duplicate 标记语义不受影响（由适配器模块的采集记录器判定 duplicateIDs）。
    /// 不绑定会话生命周期——socket 重连时代理层会重置其 duplicateIDs，本窗口表仅按
    /// 时间过期清理，避免无限增长。
    private var longConnDedupWindow: [String: Date] = [:]
    /// 双路径去重窗口时长（默认 2s，可注入便于测试）。
    var longConnDedupWindowInterval: TimeInterval = 2

    /// 响应体解码槽位（ 机制）：由 registerBinaryCodec安装 dispatch 闭包，
    /// 测试可直接注入；URLProtocol 在组装真实响应时读取。独立小锁保护（设置低频、读取高频）。
    private let decoderLock = NSLock()
    private var bodyDecoderValue: MockNetPackKit.BodyDecoder?
    var bodyDecoder: MockNetPackKit.BodyDecoder? {
        get { decoderLock.lock(); defer { decoderLock.unlock() }; return bodyDecoderValue }
        set { decoderLock.lock(); bodyDecoderValue = newValue; decoderLock.unlock() }
    }
    /// 响应体编码槽位（ 机制）：由 registerBinaryCodec安装 dispatch 闭包，
    /// URLProtocol 在回放编辑过的文本回包时调用，把文本重新编码回二进制协议字节。
    /// 与 bodyDecoder 共用同一把小锁。
    private var bodyEncoderValue: MockNetPackKit.BodyEncoder?
    var bodyEncoder: MockNetPackKit.BodyEncoder? {
        get { decoderLock.lock(); defer { decoderLock.unlock() }; return bodyEncoderValue }
        set { decoderLock.lock(); bodyEncoderValue = newValue; decoderLock.unlock() }
    }
    /// 请求体专用解码槽位：业务请求体与响应体编码不对称时（如请求体仅 AES、
    /// 响应体 gzip+AES），由 registerBinaryCodec 的 requestDecrypt 闭包安装；
    /// 未注册时为 nil，请求体不解码、回退 `[binary N bytes]` 占位。
    private var requestBodyDecoderValue: MockNetPackKit.BodyDecoder?
    var requestBodyDecoder: MockNetPackKit.BodyDecoder? {
        get { decoderLock.lock(); defer { decoderLock.unlock() }; return requestBodyDecoderValue }
        set { decoderLock.lock(); requestBodyDecoderValue = newValue; decoderLock.unlock() }
    }
    /// 请求体专用编码槽位（预留，当前无调用点）：请求体回放/改写场景使用。
    private var requestBodyEncoderValue: MockNetPackKit.BodyEncoder?
    var requestBodyEncoder: MockNetPackKit.BodyEncoder? {
        get { decoderLock.lock(); defer { decoderLock.unlock() }; return requestBodyEncoderValue }
        set { decoderLock.lock(); requestBodyEncoderValue = newValue; decoderLock.unlock() }
    }

    // MARK: - 二进制协议编解码器

    /// 一次 registerBinaryCodec 注册的 codec。加解密由业务方闭包提供；
    /// contentType 匹配 / gzip 压缩 / UTF-8 转换由 SDK 完成。
    private struct BinaryCodecRegistration {
        let key: String
        let compression: MockNetPackKit.BinaryCompression
        let responseEncrypt: @Sendable (Data) -> Data?
        let responseDecrypt: @Sendable (Data) -> Data?
        /// 请求体业务加密闭包（可选；请求体回放/改写预留，当前无调用点）。
        let requestEncrypt: (@Sendable (Data) -> Data?)?
        /// 请求体专用解密闭包（可选；nil = 请求体不解码）。
        let requestDecrypt: (@Sendable (Data) -> Data?)?
    }

    /// 已注册 codec 列表（注册顺序 = 匹配优先级，首个命中生效）。
    /// 与 bodyDecoder/bodyEncoder 共用 decoderLock。
    private var codecsValue: [BinaryCodecRegistration] = []

    /// 注册 codec：追加到列表并安装 dispatch 闭包到 bodyDecoder/bodyEncoder 槽位。
    /// - 展示链路（decrypt）：真实密文 → 业务解密 → SDK 转 UTF-8 文本；
    /// - 回放链路（encrypt）：编辑文本 → SDK 转 UTF-8 → gzip 压缩（.gzip）→ 业务加密。
    func registerBinaryCodec(
        for key: String,
        compression: MockNetPackKit.BinaryCompression,
        responseEncrypt: @escaping @Sendable (Data) -> Data?,
        responseDecrypt: @escaping @Sendable (Data) -> Data?,
        requestEncrypt: (@Sendable (Data) -> Data?)? = nil,
        requestDecrypt: (@Sendable (Data) -> Data?)? = nil
    ) {
        guard !key.isEmpty else { return }
        decoderLock.lock()
        codecsValue.append(BinaryCodecRegistration(
            key: key, compression: compression,
            responseEncrypt: responseEncrypt, responseDecrypt: responseDecrypt,
            requestEncrypt: requestEncrypt, requestDecrypt: requestDecrypt))
        installCodecDispatchLocked()
        decoderLock.unlock()
    }

    /// 测试辅助：清空已注册 codec 与 dispatch 槽位。
    func resetBinaryCodecs() {
        decoderLock.lock()
        codecsValue = []
        bodyDecoderValue = nil
        bodyEncoderValue = nil
        requestBodyDecoderValue = nil
        requestBodyEncoderValue = nil
        decoderLock.unlock()
    }

    /// 按注册顺序取首个 contentType（大小写不敏感）包含 key 的 codec。
    private func matchingCodec(for contentType: String?) -> BinaryCodecRegistration? {
        let lower = contentType?.lowercased()
        decoderLock.lock()
        defer { decoderLock.unlock() }
        guard let lower else { return nil }
        return codecsValue.first { lower.contains($0.key.lowercased()) }
    }

    /// 把 dispatch 闭包安装到 bodyDecoder/bodyEncoder 槽位（调用方须已持有 decoderLock）。
    private func installCodecDispatchLocked() {
        bodyDecoderValue = { [weak self] data, contentType in
            guard let codec = self?.matchingCodec(for: contentType) else { return nil }
            guard let plain = codec.responseDecrypt(data) else { return nil }
            guard let text = String(data: plain, encoding: .utf8) else { return nil }
            // 解码失败守卫：部分业务底层解码器（如 zlib ungzip）失败时不返回 nil，
            // 而返回错误描述文本（如 "ZYZLIB_Z_MEM_ERROR or Z_DATA_ERROR"）。识别 zlib
            // 错误宏名特征，避免把错误描述当作业务明文展示。
            guard !Self.isDecoderErrorText(text) else { return nil }
            return text
        }
        // 请求体专用解码槽位：仅当某 codec 注册了 requestDecrypt 时才启用；
        // 未注册的 codec 整体不命中（nil），请求体不解码、回退占位。
        requestBodyDecoderValue = { [weak self] data, contentType in
            guard let codec = self?.matchingCodec(for: contentType),
                  let requestDecrypt = codec.requestDecrypt else { return nil }
            guard let plain = requestDecrypt(data) else { return nil }
            guard let text = String(data: plain, encoding: .utf8) else { return nil }
            guard !Self.isDecoderErrorText(text) else { return nil }
            return text
        }
        // 请求体专用编码槽位（预留）：仅当某 codec 注册了 requestEncrypt 时才启用。
        requestBodyEncoderValue = { [weak self] text, contentType in
            guard let codec = self?.matchingCodec(for: contentType),
                  let requestEncrypt = codec.requestEncrypt else { return nil }
            guard let raw = text.data(using: .utf8) else { return nil }
            return requestEncrypt(raw)
        }
        bodyEncoderValue = { [weak self] text, contentType in
            guard let codec = self?.matchingCodec(for: contentType) else { return nil }
            guard let raw = text.data(using: .utf8) else { return nil }
            let payload: Data
            switch codec.compression {
            case .none:
                payload = raw
            case .gzip:
                guard let gz = raw.gzipCompressed() else { return nil }
                payload = gz
            }
            return codec.responseEncrypt(payload)
        }
    }

    /// 识别解码器失败时业务底层常返回的错误描述文本（zlib 错误宏名）。
    /// 业务明文 JSON 不会以这些宏名开头/包含它们，故用作失败兜底不影响正常展示。
    static func isDecoderErrorText(_ text: String) -> Bool {
        let markers = [
            "Z_DATA_ERROR", "Z_MEM_ERROR", "Z_BUF_ERROR",
            "Z_STREAM_ERROR", "Z_VERSION_ERROR", "Z_ERRNO", "Z_NEED_DICT",
        ]
        return markers.contains(where: { text.contains($0) })
    }
    private var pending: [TrafficEntry] = []
    private var pendingBytes = 0

    // MARK: - 生命周期

    /// 预注入（连接层 unconfigured 启动时调用；幂等）：仅安装 URLProtocol 注入，
    /// 不启动采集、不发起网络。目的：首次接入（无已保存服务器地址）的 App 在扫码
    /// 连接之前创建的 URLSession（如 FDNetworkCore 的 AF 单例 session）也携带拦截器，
    /// 避免"单例 session 先于注入创建而全程漏抓"。未连接时 isCapturing=false，
    /// canInit fail-open，业务零干预；扫码连接后由 start()/心跳驱动接管。
    func arm() {
        ensureInjected()
        log("URLProtocol armed (pre-connect injection installed)")
    }

    /// 安装 URLProtocol 注入（arm/start 共用；幂等，锁保护判定）：swizzle
    /// URLSessionConfiguration 类构造方法（默认/临时会话携带拦截器），并注册全局类
    /// （NSURLConnection 时代兜底）。会话未激活时 canInit 返回 false。
    private func ensureInjected() {
        lock.lock()
        guard !injectedValue else { lock.unlock(); return }
        injectedValue = true
        lock.unlock()
        URLSessionConfigurationInjector.install()
        URLProtocol.registerClass(MockNetPackURLProtocol.self)
    }

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
        longConnPending = []
        longConnPendingBytes = 0
        longConnLastSnapshot = nil
        longConnLastSnapshotAt = nil
        lock.unlock()

        // 注入（幂等）：若启动早期已由 arm() 预注入则跳过，避免重复注册拦截器类。
        ensureInjected()
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
        longConnPending = []
        longConnPendingBytes = 0
        longConnLastSnapshot = nil
        longConnLastSnapshotAt = nil
        lock.unlock()

        // 还原注入、注销全局类；已创建会话的拦截由 canInit 静态开关兜底（stop 后 false）。
        URLSessionConfigurationInjector.uninstall()
        URLProtocol.unregisterClass(MockNetPackURLProtocol.self)
        lock.lock()
        injectedValue = false   // 允许 stop 后再次 start/arm 时重新注入
        lock.unlock()
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
        // 会话切换（开始/结束）才清空待上传批次：
        // - 开始：上个会话的残留批次与新会话无关；
        // - 结束：临时记录随会话结束丢弃（与服务端清空语义一致）。
        // 值未变（心跳重复下发同一会话状态）时不清空——否则每次心跳都会丢掉
        // flush 定时器（2s）尚未触发的一整段已录流量。
        if changed {
            pending = []
            pendingBytes = 0
            longConnPending = []
            longConnPendingBytes = 0
            longConnLastSnapshot = nil
            longConnLastSnapshotAt = nil
        }
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

    // MARK: - 长连接采集（能力线 L1；L2.1 实现）

    /// 长连接采集开关（默认开；关闭后仅丢弃、不影响业务侧打点）。
    var longConnectionCaptureEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return longConnEnabledValue }
        set { lock.lock(); longConnEnabledValue = newValue; lock.unlock() }
    }

    /// 注入一条长连接记录（业务侧桥接层调用；线程安全）。
    /// 语义（决策 #2/#3/#4）：独立缓冲与独立额度（默认 1000 条，超限丢最旧，
    /// 不占用 HTTP 流量额度）；payload 完整保留 ≤10KB、超限仅存预览 ≤1KB；
    /// snapshot 事件立即入队并缓存为 30s 兜底补发源；心跳等事件不逐条合并，
    /// 随 snapshot 周期性可见。仅 capturing 且开关开启时入队。
    func recordLongConnection(_ record: LongConnectionRecordInput) {
        // L4：该通道注册了编解码器、且本次只有 raw（无 payloadText）→ 后台串行解码后入队。
        // 串行队列保证多包顺序与原 socket 收包顺序一致；解不出则保留 base64 降级。
        if record.eventType == .packet,
           record.payloadText == nil,
           let b64 = record.payloadBase64,
           let raw = Data(base64Encoded: b64) {
            if let coder = LongConnectionCollector.shared.coder(for: record.channelId) {
                SDKLog.info("decode pipeline: hit coder channel=\(record.channelId) msgId=\(record.msgId ?? "-")",
                               category: "longconn")
                decodeQueue.async {
                    var r = record
                    let context: [String: String] = [
                        "bizType": r.bizType ?? "",
                        "msgId": r.msgId ?? "",
                    ].compactMapValues { $0.isEmpty ? nil : $0 }
                    if let text = coder.decode(channelId: r.channelId, raw: raw, context: context),
                       !text.isEmpty {
                        r.payloadText = text
                        r.payloadBase64 = nil   // 三选一：有可读文本则不留 base64，避免重复存储
                    }
                    self.enqueueLongConn(r)
                }
                return
            }
            SDKLog.info("decode pipeline: packet+base64 but no coder for channel=\(record.channelId), keep base64",
                           category: "longconn")
        }
        enqueueLongConn(record)
    }

    /// 入队一条长连接记录（开关判断/截断/额度/上报；解码分支与直连分支共用）。
    private func enqueueLongConn(_ record: LongConnectionRecordInput) {
        lock.lock()
        guard running, capturingValue, longConnEnabledValue else { lock.unlock(); return }
        var r = record
        // L5.5：双路径去重（注入+代理并存时同一包不重复上报）。仅 packet 事件
        // （msgId 非空）参与；顺带清理窗口过期条目（表不绑定会话生命周期）。
        if r.eventType == .packet, let msgId = r.msgId {
            let key = r.channelId + "|" + msgId
            let now = Date()
            let expired = longConnDedupWindow.filter { now.timeIntervalSince($0.value) > longConnDedupWindowInterval }
            for k in expired.keys {
                longConnDedupWindow.removeValue(forKey: k)
            }
            if let last = longConnDedupWindow[key], now.timeIntervalSince(last) <= longConnDedupWindowInterval {
                lock.unlock()
                return // 双路径重复：丢弃第二条
            }
            longConnDedupWindow[key] = now
        }
        truncateLongConnPayload(&r)
        if r.eventType == .snapshot, r.snapshot != nil {
            longConnLastSnapshot = r
            longConnLastSnapshotAt = Date()
        }
        let bytes = estimateLongConnBytes(r)
        longConnPending.append(r)
        longConnPendingBytes += bytes
        // 独立额度：超限丢最旧（rolling window）。
        while longConnPending.count > maxLongConnEntries {
            let dropped = longConnPending.removeFirst()
            longConnPendingBytes -= estimateLongConnBytes(dropped)
        }
        let count = longConnPending.count
        let tooMany = count >= maxLongConnBatchCount
        let tooBig = longConnPendingBytes >= maxLongConnBatchBytes
        lock.unlock()

        if tooMany || tooBig {
            flush()
        }
    }

    /// payload 截断（决策 #2）：完整保留 ≤10KB；超限仅存预览（≤1KB），
    /// 原 payload 字段清空。text 优先（三选一），base64 按长度估算字节。
    private func truncateLongConnPayload(_ r: inout LongConnectionRecordInput) {
        if let text = r.payloadText, text.utf8.count > maxLongConnPayloadBytes {
            r.payloadPreview = String(decoding: text.utf8.prefix(maxLongConnPreviewBytes), as: UTF8.self)
            r.payloadText = nil
        } else if let b64 = r.payloadBase64,
                  b64.utf8.count * 3 / 4 > maxLongConnPayloadBytes {
            // 预览截断为前 maxLongConnPreviewBytes 原始字节对应的 base64 长度。
            r.payloadPreview = String(String(b64).prefix(maxLongConnPreviewBytes * 4 / 3))
            r.payloadBase64 = nil
        }
    }

    /// 长连接记录字节估算（入队计数用；与 HTTP 的估算口径独立）。
    private func estimateLongConnBytes(_ r: LongConnectionRecordInput) -> Int {
        var n = 256
        n += r.payloadText?.utf8.count ?? 0
        n += (r.payloadBase64?.utf8.count ?? 0) * 3 / 4
        n += r.payloadPreview?.utf8.count ?? 0
        return n
    }

    /// 立即上传待上传批次（定时/阈值/会话激活时调用；无数据或无会话则 no-op）。
    /// HTTP 流量与长连接日志分通道取批、分别上传（互不干扰；长连接走
    /// POST /sessions/{id}/longconn）。
    func flush() {
        let batch: [TrafficEntry]
        let longBatches: [String: [LongConnectionRecordInput]]
        let sessionID: String
        let serverURL: URL
        let appID: String
        let did: String
        lock.lock()
        guard capturingValue,
              let sid = sessionIDValue,
              let url = serverURLValue,
              let app = appIDValue,
              let d = didValue else {
            lock.unlock()
            return
        }
        batch = pending
        pending = []
        pendingBytes = 0
        // 长连接：按 channelId 分组取批；snapshot 30s 兜底随批次补发。
        var groups: [String: [LongConnectionRecordInput]] = [:]
        for entry in longConnPending {
            groups[entry.channelId, default: []].append(entry)
        }
        if let last = longConnLastSnapshot {
            let now = Date()
            let needsFallback: Bool
            if let at = longConnLastSnapshotAt {
                needsFallback = now.timeIntervalSince(at) >= longConnSnapshotFallbackInterval
            } else {
                needsFallback = true
            }
            if needsFallback {
                groups[last.channelId, default: []].append(last)
                longConnLastSnapshotAt = now
            }
        }
        longBatches = groups
        longConnPending = []
        longConnPendingBytes = 0
        sessionID = sid
        serverURL = url
        appID = app
        did = d
        guard !batch.isEmpty || !longBatches.isEmpty else {
            lock.unlock()
            return
        }
        lock.unlock()

        let client = makeClient(serverURL: serverURL)
        if !batch.isEmpty {
            let req = TrafficUploadRequest(app: appID, did: did, sessionId: sessionID, entries: batch)
            Task { [weak self] in
                do {
                    let _: TrafficUploadResponse = try await client.post("traffic", body: req, as: TrafficUploadResponse.self)
                    self?.log("uploaded \(batch.count) traffic entries")
                } catch {
                    // 需求 ：不做本地缓存、不重传；失败批次直接丢弃。
                    self?.log("traffic upload failed: \(error.localizedDescription); batch dropped (no retry)")
                }
            }
        }
        for (channelID, records) in longBatches {
            let req = LongConnUploadRequest(channelId: channelID, records: records)
            Task { [weak self] in
                do {
                    let _: LongConnUploadResponse = try await client.post("sessions/\(sessionID)/longconn", body: req, as: LongConnUploadResponse.self)
                    self?.log("uploaded \(records.count) longconn records (channel \(channelID))")
                } catch {
                    // 与 HTTP 同语义：不做本地缓存、不重传；失败批次直接丢弃。
                    self?.log("longconn upload failed: \(error.localizedDescription); batch dropped (no retry)")
                }
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

    /// 输出一条 SDK 日志：先经注入的 logHandler（宿主/测试捕获），
    /// 再落 OSLog（SDKLog，iOS 13 兼容包装）。
    private func log(_ message: String) {
        let handler = withLock { logHandler }
        handler?(message)
        SDKLog.info(message, category: "capture")
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
