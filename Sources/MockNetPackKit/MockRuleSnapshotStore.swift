import Foundation

/// Mock 规则快照持久化（iOS-AN9：启动早的请求也能被 Mock）。
///
/// 与 ServerAddressStore/DIDStore 同模式：UserDefaults 持久化 + defaults 可注入
/// （单测用独立 suite 隔离，避免读取真实设备残留快照）。
///
/// 语义：
/// - 快照 = {version, rules}（effective=true 规则集，字段对齐契约 MockRule；
///   ruleId 不落盘——apply 存的 rules 为服务端解码态，ruleId 恒 nil）。
/// - 冷启动时加载 → 启动握手期即可用上次同步的快照匹配 Mock（规则同步在心跳后，
///   冷启动进程内快照为空是「启动早请求无法 Mock」的根因）。
/// - 断连保护：连接失败达阈值（见 ConnectionController）调用 clear() 永久清除
///   （内存+磁盘），连接恢复后以 sinceVersion=0 重新从服务端下载。
struct MockRuleSnapshotStore {

    /// UserDefaults key（与安卓同前缀体系 mocknetpack.mock.rules.v1；快照为进程级，
    /// 不按 appID/did 隔离，见方案开放问题 #2）。
    static let key = "mocknetpack.mock.rules.v1.snapshot"

    /// 快照结构 = {version, rules}；ruleId 不落盘（apply 存的 rules 天然 ruleId=nil）。
    struct Snapshot: Codable, Equatable {
        let version: Int
        let rules: [MockRule]
    }

    /// 存储；默认 .standard，测试注入独立 suite。
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 保存快照（版本 + 规则集）。UserDefaults set 为同步内存更新 + 异步落盘。
    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// 读取快照；无快照返回 nil。解码失败（契约损坏）→ 清掉坏数据再返回 nil，
    /// 使下次同步可正常重写磁盘（对齐安卓 F5：坏快照不永久禁用持久化）。
    func load() -> Snapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            defaults.removeObject(forKey: Self.key) // 清坏文件
            return nil
        }
        return snapshot
    }

    /// 清除快照（断连保护 / 永久拒绝时调用）。
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
