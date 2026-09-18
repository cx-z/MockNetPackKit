import Foundation

/// did 生成与持久化。
///
/// 契约约束（server/openapi/mocknetpack.yaml v0.1.0）：
/// - SDK 生成，App 作用域内唯一；
/// - App 内持久化（重启不变）；
/// - 不依赖设备硬件标识（隐私/合规；同机多 App 各自独立）。
///
/// 实现：随机 UUID + UserDefaults 持久化。key 带 appID 前缀，
/// 不同 App 互不串扰（相同 did 出现在不同 App 下是允许的，
/// 服务端以 (app, did) 维度隔离）。
enum DIDStore {
    /// 取回（或首次生成并持久化）指定 App 的 did。
    /// - Parameters:
    ///   - appID: App 标识（Bundle ID 或显式传入）。
    ///   - defaults: 存储；默认 `UserDefaults.standard`，测试可注入独立 suite。
    static func did(forApp appID: String, defaults: UserDefaults = .standard) -> String {
        let key = "mocknetpack.did.v1.\(appID)"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let newDID = UUID().uuidString.lowercased()
        defaults.set(newDID, forKey: key)
        return newDID
    }

    /// 清除指定 App 的 did（仅测试用）。
    static func reset(forApp appID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "mocknetpack.did.v1.\(appID)")
    }
}
