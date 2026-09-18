import Foundation

/// MockNetPackKit 的公共入口占位。
///
/// ⚠️ M0 阶段仅为骨架，不实现任何抓包/Mock 逻辑（属 M1+）。
/// 设计约束（见 tasks/需求文档.md §7.7）：
/// - 本 SDK **只应存在于 Debug 构建**；Release 产物不得包含本库。
/// - 业务侧对本类型的所有调用必须用 `#if DEBUG` 包裹（见 README「接入约束」）。
public enum MockNetPackKit {

    /// SDK 版本号（骨架阶段）。
    public static let version = "0.0.1-m0"

    /// 自检：进程内是否已接入。M0 仅返回 true 作为占位，M1 起替换为真实初始化。
    public static var isAttached: Bool { true }
}
