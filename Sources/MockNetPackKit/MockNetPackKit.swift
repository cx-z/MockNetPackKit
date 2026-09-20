import Foundation

/// MockNetPackKit 公共入口（连接层，M1.5）。
///
/// 本 SDK 自身不做 Debug/Release 判断——是否集成、如何隔离构建完全由业务
/// App 决定；接入方 KK 要求 Release 产物不含本 SDK，由 KK 构建集成层保证
/// （见 tasks/M0-SDK接入要点.md）。
public enum MockNetPackKit {

    /// SDK 版本号。
    public static let version = "0.2.0-m4"

    /// 响应体协议解码器（M4）：由业务 App 注入，把私有二进制协议字节
    /// （如 xcp AES+gzip）解成可读 UTF-8 文本，仅用于 Web 展示；原始字节的
    /// base64 仍单独保留用于回放。返回 nil 表示解不出（回退 `[binary N bytes]`）。
    /// - Parameters:
    ///   - data: 响应体原始字节（未截断的完整数据，调用方负责控制体积）。
    ///   - contentType: 响应 Content-Type 头，可用于判断是否需要解码。
    public typealias BodyDecoder = @Sendable (_ data: Data, _ contentType: String?) -> String?

    /// 注入响应体协议解码器（M4）。nil 表示移除解码器。在后台线程调用，
    /// 失败/未就绪时返回 nil，SDK 回退到 `[binary N bytes]` 占位。
    public static func setBodyDecoder(_ decoder: BodyDecoder?) {
        TrafficCaptureController.shared.bodyDecoder = decoder
    }

    /// 启动连接层：生成/读取 did → 注册设备 → 周期心跳 → 会话状态推导。
    /// - Parameters:
    ///   - server: 服务器 base URL（形如 `http://host:4290/api/v1`）。
    ///   - appID: App 标识，默认取 Bundle ID；SDK 生成并持久化 did 的作用域。
    ///   - appVersion: App 版本，默认取 CFBundleShortVersionString。
    ///   - logHandler: 日志回调（可选；默认走 OSLog）。
    /// 幂等：已在运行则忽略。
    public static func start(server: URL,
                             appID: String? = nil,
                             appVersion: String? = nil,
                             logHandler: (@Sendable (String) -> Void)? = nil) {
        ConnectionController.shared.start(
            server: server,
            appID: appID ?? Self.bundleID,
            appVersion: appVersion ?? Self.bundleVersion,
            sdkVersion: version,
            osVersion: Self.osVersion,
            logHandler: logHandler
        )
    }

    /// 停止连接层：停心跳、清状态（did 保留，下次 start 复用）。
    public static func stop() {
        ConnectionController.shared.stop()
    }

    /// 连接层是否在运行。
    public static var isRunning: Bool { ConnectionController.shared.isRunning }

    /// 本设备 did（start 后可用；App 作用域内唯一、重启不变）。
    public static var did: String? { ConnectionController.shared.did }

    /// 连接状态（connecting / connected / offline）。
    public static var connectionState: ConnectionState { ConnectionController.shared.connectionState }

    /// 会话状态（idle / capturing），由心跳响应 session 字段推导。
    public static var sessionState: SessionState { ConnectionController.shared.sessionState }

    /// 会话状态变化回调（主线程派发；M2 起可据此启停采集）。
    public static var onSessionStateChange: (@Sendable (SessionState) -> Void)? {
        get { ConnectionController.shared.onSessionStateChange }
        set { ConnectionController.shared.onSessionStateChange = newValue }
    }

    /// 连接状态变化回调（主线程派发）。
    public static var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)? {
        get { ConnectionController.shared.onConnectionStateChange }
        set { ConnectionController.shared.onConnectionStateChange = newValue }
    }

    // MARK: - 系统信息

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown.app"
    }

    private static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private static var osVersion: String {
        #if os(iOS)
        return UIDevice.current.systemVersion
        #elseif os(macOS)
        return ProcessInfo.processInfo.operatingSystemVersionString
        #else
        return ""
        #endif
    }
}
