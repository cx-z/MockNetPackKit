import Foundation

/// 服务器地址持久化（M9.2）。
///
/// 扫码连接的核心收益：客户端不再写死服务器地址。扫码成功后地址写入本地，
/// 之后 `start()` 无参直连、重启免扫码（A2）；地址变更只需重新扫码（A3 切换）。
///
/// 对齐 DIDStore 模式：UserDefaults + appID 前缀 key，不同 App 互不串扰。
/// 协议：值存 URL 的 absoluteString；非法/空值按未配置处理。
enum ServerAddressStore {

    /// UserDefaults key 前缀（did 同前缀体系 `mocknetpack.did.v1.<appID>`）。
    private static func key(forApp appID: String) -> String {
        "mocknetpack.server.v1.\(appID)"
    }

    /// 保存服务器地址。
    static func save(_ url: URL, forApp appID: String, defaults: UserDefaults = .standard) {
        defaults.set(url.absoluteString, forKey: key(forApp: appID))
    }

    /// 读取已保存的服务器地址；未配置/值非法返回 nil。
    static func load(forApp appID: String, defaults: UserDefaults = .standard) -> URL? {
        guard let raw = defaults.string(forKey: key(forApp: appID)), !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme, (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// 清除服务器地址（Debug 页「重置服务器」）。
    static func clear(forApp appID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(forApp: appID))
    }

    /// 清除（仅测试用）。
    static func reset(forApp appID: String, defaults: UserDefaults = .standard) {
        clear(forApp: appID, defaults: defaults)
    }
}
