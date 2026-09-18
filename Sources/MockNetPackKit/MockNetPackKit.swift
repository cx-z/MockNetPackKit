import Foundation

/// MockNetPackKit 的公共入口占位。
///
/// ⚠️ M0 阶段仅为骨架，不实现任何抓包/Mock 逻辑（属 M1+）。
///
/// 集成说明：本 SDK 自身不做 Debug/Release 判断——是否集成、如何隔离构建，
/// 完全由业务 App 自行决定。接入方 Knocknock(KK) 的要求是：
/// Release 产物中不包含本 SDK 的代码/符号（不仅是"不生效"），
/// 由接入方在构建集成层保证（见 tasks/M0-SDK接入要点.md）。
public enum MockNetPackKit {

    /// SDK 版本号（骨架阶段）。
    public static let version = "0.0.1-m0"

    /// 自检：进程内是否已接入。M0 仅返回 true 作为占位，M1 起替换为真实初始化。
    public static var isAttached: Bool { true }
}
