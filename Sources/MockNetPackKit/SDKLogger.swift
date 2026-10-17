import Foundation
import OSLog

/// SDK 内部日志入口（iOS 13 兼容）。
/// 长连接接入模块沿用主 SDK 统一日志出口（category 一致
/// 可观测）→ 公开。
///
/// `Logger` 与 OSLog 插值（privacy）仅 iOS 14+ 可用，而 SDK 最低部署
/// 目标为 iOS 13：iOS 14+ 走统一日志（隐私标注 public），iOS 13 及更早
/// 退化为 `os_log`（iOS 10+），两侧输出内容一致。
public enum SDKLog {
    /// 输出 info 级日志。
    /// - Parameters:
    ///   - message: 日志正文（已含插值）。
    ///   - category: 日志分类，沿用原 Logger 的 connection/capture/mock。
    public static func info(_ message: String, category: String) {
        if #available(iOS 14.0, macOS 11.0, *) {
            Logger(subsystem: "com.mocknetpack.kit", category: category)
                .info("\(message, privacy: .public)")
        } else {
            os_log("%{public}@", log: OSLog.default, type: .info, message)
        }
    }

    /// 输出 error 级日志。
    /// - Parameters:
    ///   - message: 日志正文（已含插值）。
    ///   - category: 日志分类，沿用原 Logger 的 connection/capture/mock。
    public static func error(_ message: String, category: String) {
        if #available(iOS 14.0, macOS 11.0, *) {
            Logger(subsystem: "com.mocknetpack.kit", category: category)
                .error("\(message, privacy: .public)")
        } else {
            os_log("%{public}@", log: OSLog.default, type: .error, message)
        }
    }
}
