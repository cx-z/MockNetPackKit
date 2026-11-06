import Foundation

/// 一次被转发请求的终态记录器。
///
/// 背景：原请求超时/取消时，URL 加载系统先调用 `stopLoading` 再释放
/// `URLProtocol` 实例；若转发完成回调只捕获 `[weak self]`，终态记录会随实例
/// 释放整条丢失（超时与主动取消均可稳定复现）。本类独立于 protocol 实例持有
/// 记录所需快照，由转发完成回调强捕获，保证"已进入抓包链路"的请求恰好记录
/// 一条终态，即使 protocol 已释放。
///
/// 线程安全：`finish`/`markClientAborted` 可能来自转发 session 回调线程、
/// URL 加载线程与兜底定时器，统一由 `lock` 保护 `finished`/`abortReason`；
/// 组包与上报在锁外执行，避免持锁做编码/IO。
final class TrafficTerminalRecorder: @unchecked Sendable {

    /// 终态阶段：平台据此区分 HTTP 错误、传输层错误与客户端中止。
    enum Stage: String {
        /// 收到 HTTP 响应（含 4xx/5xx）。
        case httpResponse
        /// 传输层错误（连接失败、连接中断等）。
        case transportError
        /// 客户端在 request.timeoutInterval 截止点中止（按截止时间推断）。
        case clientTimeout
        /// 客户端主动取消。
        case clientCancelled
    }

    /// 客户端中止原因（`stopLoading` 时按 request.timeoutInterval 推断）。
    enum AbortReason: String {
        case timeout
        case cancelled
    }

    /// 判定"在截止点中止"的时间容差（秒）：覆盖定时器抖动与回调排队。
    static let timeoutTolerance: TimeInterval = 0.5

    private let lock = NSLock()
    private var finished = false
    private var abortReason: AbortReason?

    /// 请求创建时刻（init 阶段），用于耗时与时间戳（含请求体读取时间）。
    let startTime: Date
    private let method: String
    private let url: String
    private let path: String
    private let query: String
    private let requestHeaders: [String: [String]]
    /// init 阶段抢读到的原始请求体（可能为空）。
    private let requestBody: Data?
    private let requestContentType: String?
    /// 请求创建时绑定的采集代次；代次失效时本次记录按既有语义丢弃。
    private let captureGeneration: UInt64?
    /// 请求级超时（秒）：用于推断客户端中止是超时还是主动取消。
    private let requestTimeout: TimeInterval
    /// 采集器（进程单例），用于按代次入队。
    private let controller: TrafficCaptureController

    /// 创建记录器并快照记录所需字段；调用方须已抢读请求体。
    init(startTime: Date,
         request: URLRequest,
         requestBody: Data?,
         captureGeneration: UInt64?,
         controller: TrafficCaptureController) {
        self.startTime = startTime
        self.method = request.httpMethod ?? "GET"
        self.url = request.url?.absoluteString ?? ""
        self.path = request.url?.path ?? ""
        self.query = request.url?.query ?? ""
        var headers: [String: [String]] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            headers[key] = [value]
        }
        self.requestHeaders = headers
        self.requestBody = requestBody
        self.requestContentType = request.value(forHTTPHeaderField: "Content-Type")
        self.captureGeneration = captureGeneration
        self.requestTimeout = request.timeoutInterval
        self.controller = controller
    }

    /// 标记客户端已中止（stopLoading 触发）：按"距截止时间是否已到点"区分超时与主动取消。
    /// 可重复调用，首次结果生效；已产生终态时忽略。
    func markClientAborted(at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, abortReason == nil else { return }
        let elapsed = date.timeIntervalSince(startTime)
        if requestTimeout > 0, elapsed >= requestTimeout - Self.timeoutTolerance {
            abortReason = .timeout
        } else {
            abortReason = .cancelled
        }
    }

    /// 转发完成回调入口：记录恰好一条终态。
    /// 观测优先：转发任务实际报 -1001 时错误码是真实观测值，`timeoutInferred` 必须缺省，
    /// 不再取决于 `stopLoading` 与完成回调的先后顺序；
    /// 未观测到 -1001 时沿用 `stopLoading` 对中止时刻的推断。
    /// 该优先级同时覆盖"abortReason 已是 cancelled、但转发任务观测到 -1001"（
    /// 会话级超时短于 request.timeoutInterval 被误判为主动取消）的情形。
    /// - Parameters:
    ///   - response: 转发任务收到的响应（可能为 nil）。
    ///   - data: 已收到的响应体（可能为 nil）。
    ///   - error: 转发任务终态错误（可能为 nil）。
    func finish(response: URLResponse?, data: Data?, error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        var reason = abortReason
        lock.unlock()
        let nsError = error as NSError?
        let observedTimeout = nsError?.domain == NSURLErrorDomain
            && nsError?.code == NSURLErrorTimedOut
        if observedTimeout {
            reason = .timeout
        }
        let inferred = (reason == .timeout) && !observedTimeout
        emit(response: response, data: data, error: error, reason: reason,
             timeoutInferred: inferred, observedCompletion: true)
    }

    /// 兜底入口：`stopLoading` 后转发任务迟迟不回调（如共享 session 被系统回收）时，
    /// 强制补一条终态，保证"已进入抓包链路"的请求不留空档。
    func finishWithoutCompletion() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let reason = abortReason ?? .cancelled
        lock.unlock()
        emit(response: nil, data: nil, error: nil, reason: reason,
             timeoutInferred: reason == .timeout, observedCompletion: false)
    }

    // MARK: - 组包与上报

    /// 组装 TrafficEntry 并交给采集器；锁外执行，编码/解码失败不伪造字段。
    /// - Parameters:
    ///   - timeoutInferred: 超时是否来自 `stopLoading` 的截止点推断（观测到 -1001 时为 false）。
    private func emit(response: URLResponse?,
                      data: Data?,
                      error: Error?,
                      reason: AbortReason?,
                      timeoutInferred: Bool,
                      observedCompletion: Bool) {
        let durationMs = max(0, Int(Date().timeIntervalSince(startTime) * 1000))
        let http = response as? HTTPURLResponse
        let nsError = error as NSError?

        // 终态分类：客户端中止优先（此时转发任务错误通常是 -999，不能代表客户端真实终态）。
        let stage: Stage
        var errorDomain: String?
        var errorCode: Int?
        var errorDescription: String?

        if let reason {
            if reason == .timeout {
                stage = .clientTimeout
                errorDomain = NSURLErrorDomain
                errorCode = NSURLErrorTimedOut
                errorDescription = String(
                    format: timeoutInferred
                        ? "请求超时（推断）：客户端在 request.timeoutInterval %.1fs 截止点中止"
                        : "请求超时：转发任务在 request.timeoutInterval %.1fs 截止点返回 -1001",
                    requestTimeout)
            } else {
                stage = .clientCancelled
                errorDomain = nsError?.domain
                errorCode = nsError?.code
                errorDescription = nsError?.localizedDescription ?? "请求已取消（客户端主动取消）"
            }
        } else if let nsError {
            stage = .transportError
            errorDomain = nsError.domain
            errorCode = nsError.code
            errorDescription = nsError.localizedDescription
        } else {
            stage = .httpResponse
        }

        var entry = TrafficEntry(
            timestamp: startTime,
            method: method,
            url: url,
            path: path,
            query: query,
            requestHeaders: requestHeaders,
            requestBody: "",
            statusCode: http?.statusCode,
            responseHeaders: http.map { MockNetPackURLProtocol.headerFields($0.allHeaderFields) },
            responseBody: nil,
            error: summaryText(stage: stage, domain: errorDomain, code: errorCode,
                               description: errorDescription, timeoutInferred: timeoutInferred,
                               observedCompletion: observedCompletion),
            durationMs: durationMs,
            matchedRuleId: nil
        )
        let requestParts = MockNetPackURLProtocol.bodyParts(requestBody)
        entry.requestBody = requestParts.text
        entry.requestBodyBase64 = requestParts.base64
        if let requestBody, !requestBody.isEmpty {
            entry.requestBodyDecoded = MockNetPackURLProtocol.decodedBody(
                requestBody, contentType: requestContentType, isRequest: true)
        }
        entry.errorDomain = errorDomain
        entry.errorCode = errorCode
        entry.errorDescription = errorDescription
        entry.terminalStage = stage.rawValue
        entry.timeoutInferred = timeoutInferred ? true : nil
        if let reason {
            entry.clientAbort = true
            entry.clientAbortReason = reason.rawValue
        }

        if let data, !data.isEmpty {
            let responseParts = MockNetPackURLProtocol.bodyParts(data)
            entry.responseBody = responseParts.text
            entry.responseBodyBase64 = responseParts.base64
            entry.responseBodyDecoded = MockNetPackURLProtocol.decodedBody(
                data, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
        }

        if let captureGeneration {
            controller.record(entry, generation: captureGeneration)
        }
    }

    /// 生成兼容旧展示/旧服务端的人类可读摘要（结构化字段仍保留 domain/code）。
    /// 观测到超时时错误码已写进描述，不再追加转发任务的终态（否则 -1001 重复一遍）；
    /// 推断超时时追加转发任务实际错误（通常是 -999），提示两者不一致。
    private func summaryText(stage: Stage,
                             domain: String?,
                             code: Int?,
                             description: String?,
                             timeoutInferred: Bool,
                             observedCompletion: Bool) -> String? {
        let observed = [domain, code.map { String($0) }].compactMap { $0 }.joined(separator: "/")
        switch stage {
        case .httpResponse:
            return nil
        case .clientTimeout:
            var text = description ?? "请求超时（推断）"
            if !observedCompletion { text += "；未收到转发任务终态回调" }
            if timeoutInferred && !observed.isEmpty { text += "（转发任务终态：\(observed)）" }
            return text
        case .clientCancelled:
            return description ?? "请求已取消（客户端主动取消）"
        case .transportError:
            return description ?? observed
        }
    }
}
