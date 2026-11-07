import Foundation

/// M15 大图字节治理：按 media ref 拉取规则 blob，做进程内 LRU 缓存与并发取数去重。
///
/// 语义：
/// - 规则 `MockResponse.media` 存在时，回放前用
///   `GET devices/{app}/{did}/mock-rules/{ruleId}/media` 取原始字节。
/// - **LRU**：key = media.sha256（规则编辑后字节变化 → 新 key，不会拿到旧图），
///   按字节上限（32MB）淘汰最久未用；重复回放同一图片不再走网络。
/// - **并发去重**：同一 sha256 同时被多个请求命中时只发一次网络请求，结果广播给
///   所有等待者（避免批量图片请求把 SDK 自身通道打满）。
/// - **失败不吞**：返回 nil 由调用方 fail-open —— 记一条带 error 的命中流量并转发
///   真实请求，业务侧与「未命中规则」表现一致。
/// - 尺寸校验：返回字节数与 `media.size` 不一致视为失败（防止中间层截断/改写）。
final class RuleMediaCache: @unchecked Sendable {

    static let shared = RuleMediaCache()

    // MARK: - 测试注入点

    /// 下载客户端工厂：测试注入 MockURLProtocol 的 session 配置。
    var clientFactory: (@Sendable (URL) -> ConnectionClient)?
    /// 缓存字节上限（执行文档口径 32MB，可注入便于测试淘汰）。
    var maxCacheBytes = 32 * 1024 * 1024

    // MARK: - 缓存（锁保护）

    private var cache: [String: Data] = [:]
    /// LRU 顺序：最旧在前；命中时移到末尾。
    private var order: [String] = []
    private var cachedBytes = 0
    /// 在飞请求：sha256 → 等待回调（并发去重：同一 blob 只发一次网络请求）。
    private var inflight: [String: [@Sendable (Data?) -> Void]] = [:]
    private let lock = NSLock()

    /// 下载专用串行队列：URLProtocol 在加载线程同步调用，下载必须异步进行，
    /// 否则会阻塞所有被拦截的业务请求。
    private let queue = DispatchQueue(label: "com.mocknetpack.media", qos: .utility)

    /// 按规则取字节。completion 恰好回调一次（缓存命中 / 网络返回 / 去重合并），
    /// 失败回传 nil 由调用方 fail-open。
    func load(ruleID: String, media: MediaRef, completion: @escaping @Sendable (Data?) -> Void) {
        // 命中缓存：锁内取数据与 LRU 触达，锁外回调（避免回调里再入锁）。
        lock.lock()
        if let cached = cache[media.sha256] {
            touchLocked(media.sha256)
            lock.unlock()
            completion(cached)
            return
        }
        // 已有同 blob 的在飞请求：挂到等待列表，不再发第二次网络请求。
        if inflight[media.sha256] != nil {
            inflight[media.sha256]?.append(completion)
            lock.unlock()
            return
        }
        inflight[media.sha256] = [completion]
        lock.unlock()

        guard let ctx = TrafficCaptureController.shared.mediaReplayContext else {
            finish(sha256: media.sha256, data: nil)
            return
        }
        let client = clientFactory?(ctx.serverURL) ?? ConnectionClient(baseURL: ctx.serverURL)
        let path = "devices/\(ctx.app)/\(ctx.did)/mock-rules/\(ruleID)/media"
        let sha = media.sha256
        let expectSize = media.size
        queue.async {
            Task {
                do {
                    let data = try await client.getData(path)
                    if expectSize > 0 && Int64(data.count) != expectSize {
                        SDKLog.error("media size mismatch rule=\(ruleID) got=\(data.count) want=\(expectSize)",
                                     category: "mock")
                        self.finish(sha256: sha, data: nil)
                    } else {
                        self.store(data, sha256: sha)
                        self.finish(sha256: sha, data: data)
                    }
                } catch {
                    SDKLog.error("media fetch failed rule=\(ruleID): \(error.localizedDescription)",
                                 category: "mock")
                    self.finish(sha256: sha, data: nil)
                }
            }
        }
    }

    /// 清空缓存与在飞表（stop / 测试用）。
    ///
    /// 在飞请求必须在这里显式收口：`load` 的 completion 恰好回调一次，是
    /// URLProtocol media 分支唯一的完成路径。若只清表不回调，停止抓包的瞬间
    /// 被拦下的请求既没有 mock 回包、也没有错误、也没有转发，宿主只能干等到
    /// 自身 URLSession 超时。回调 nil 表示「取数失败」，调用方按既有 fail-open
    /// 逻辑转发真实请求。
    func reset() {
        lock.lock()
        cache.removeAll()
        order.removeAll()
        cachedBytes = 0
        let drained = inflight
        inflight.removeAll()
        lock.unlock()
        // 锁外回调：waiters 是外部闭包（会回到 URLProtocol），持锁调用有重入风险。
        for waiters in drained.values {
            for waiter in waiters { waiter(nil) }
        }
    }

    /// 当前缓存字节数（测试断言用）。
    var cachedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedBytes
    }

    // MARK: - 缓存实现（调用方不得持锁）

    private func touchLocked(_ sha256: String) {
        guard let idx = order.firstIndex(of: sha256) else { return }
        order.remove(at: idx)
        order.append(sha256)
    }

    private func store(_ data: Data, sha256: String) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let old = cache[sha256] {
            cachedBytes -= old.count
            if let idx = order.firstIndex(of: sha256) { order.remove(at: idx) }
        }
        cache[sha256] = data
        order.append(sha256)
        cachedBytes += data.count
        // 单条即可超过上限时也要先放入（否则大图永远无法缓存），随后按 LRU 淘汰其余。
        while cachedBytes > maxCacheBytes, let oldest = order.first, oldest != sha256 {
            order.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cachedBytes -= evicted.count
            }
        }
        if cachedBytes > maxCacheBytes {
            cache.removeValue(forKey: sha256)
            order.removeAll { $0 == sha256 }
            cachedBytes -= data.count
        }
    }

    /// 收口在飞请求：锁内取走等待回调，锁外逐个回调（不在持锁时调用外部闭包）。
    private func finish(sha256: String, data: Data?) {
        lock.lock()
        let waiters = inflight.removeValue(forKey: sha256) ?? []
        lock.unlock()
        for waiter in waiters { waiter(data) }
    }
}
