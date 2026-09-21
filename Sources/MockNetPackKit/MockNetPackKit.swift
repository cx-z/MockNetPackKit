import Foundation

/// MockNetPackKit 公共入口（连接层，M1.5）。
///
/// 本 SDK 自身不做 Debug/Release 判断——是否集成、如何隔离构建完全由业务
/// App 决定；接入方 KK 要求 Release 产物不含本 SDK，由 KK 构建集成层保证
/// （见 tasks/M0-SDK接入要点.md）。
public enum MockNetPackKit {

    /// SDK 版本号。
    public static let version = "0.2.0-m6"

    /// 响应体协议解码器（M4）：把私有二进制协议字节（如 xcp AES+gzip）解成可读
    /// UTF-8 文本，仅用于 Web 展示。M6.1 起为内部机制，由 registerBinaryCodec
    /// 安装 dispatch 闭包；测试可直接注入。返回 nil 表示解不出（回退 `[binary N bytes]`）。
    /// - Parameters:
    ///   - data: 响应体原始字节（未截断的完整数据，调用方负责控制体积）。
    ///   - contentType: 响应 Content-Type 头，可用于判断是否需要解码。
    typealias BodyDecoder = @Sendable (_ data: Data, _ contentType: String?) -> String?

    /// 响应体协议编码器（M5）：与 BodyDecoder 对称，把 Web 上编辑过的可读
    /// UTF-8 文本重新编码回私有二进制协议字节（如 xcp 的 gzip+AES），用于 Mock
    /// 回放。M6.1 起为内部机制，由 registerBinaryCodec 安装 dispatch 闭包。
    /// 返回 nil 表示编不了（SDK 回退到 bodyBase64 原始字节或 UTF-8 文本）。
    /// - Parameters:
    ///   - text: Web 编辑后的完整回包文本（已解码格式，通常是 JSON）。
    ///   - contentType: 响应 Content-Type 头，可用于判断是否需要编码。
    typealias BodyEncoder = @Sendable (_ text: String, _ contentType: String?) -> Data?

    /// 二进制协议压缩方式（M6.1）。当前仅标准 gzip 有实际使用场景；
    /// `.none` 表示不压缩（仅 UTF-8 转换 + 业务加解密）。
    public enum BinaryCompression: Sendable {
        /// 不压缩。
        case none
        /// 标准 gzip（1f 8b 头），由 SDK 内置 zlib 产出。
        case gzip
    }

    /// 注册一个二进制协议编解码器（M6.1）。一次注册同时接管两条链路：
    /// - `decrypt`（解析抓到的包，展示链路）：真实响应的二进制密文 → 业务 AES 解密
    ///   → 明文（可转 UTF-8 的字节）；SDK 负责按 contentType 匹配并把结果转成可读文本。
    /// - `encrypt`（修改 mock 的数据，回放链路）：Web 编辑后的文本 → SDK 转 UTF-8 →
    ///   按 compression 压缩 → 业务 AES 加密 → 密文字节用于 Mock 回包。
    ///
    /// 压缩语义（已定）：gzip 压缩由 SDK 完成（产出标准 1f 8b）；gzip 解压由业务方
    /// 在 `decrypt` 闭包内完成（如 KK 的 `decodeAes(data, ungzip: true)`）。
    ///
    /// 匹配：按注册顺序，contentType（大小写不敏感）包含 `contentTypeKey` 即命中，
    /// 首个命中生效；未命中返回 nil，SDK 走既有 fallback（bodyBase64 → UTF-8）。
    /// 可注册多个 codec（不同 contentTypeKey）。
    ///
    /// - Parameters:
    ///   - contentTypeKey: contentType 匹配键，例如 "xcp"。
    ///   - compression: 压缩方式（SDK 在 encrypt 前执行）。
    ///   - encrypt: 业务加密闭包，入参为 SDK 压缩后的字节，返回密文（nil 表示失败）。
    ///   - decrypt: 业务解密闭包，入参为原始密文，返回明文（nil 表示失败）。
    public static func registerBinaryCodec(
        for contentTypeKey: String,
        compression: BinaryCompression,
        encrypt: @escaping @Sendable (Data) -> Data?,
        decrypt: @escaping @Sendable (Data) -> Data?
    ) {
        TrafficCaptureController.shared.registerBinaryCodec(
            for: contentTypeKey,
            compression: compression,
            encrypt: encrypt,
            decrypt: decrypt
        )
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
