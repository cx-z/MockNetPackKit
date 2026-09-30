import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// MockNetPackKit 公共入口（连接层，M1.5）。
///
/// 本 SDK 自身不做 Debug/Release 判断——是否集成、如何隔离构建完全由业务
/// App 决定；接入方要求 Release 产物不含本 SDK，由接入方构建集成层保证
/// （见 tasks/M0-SDK接入要点.md）。
public enum MockNetPackKit {

    /// SDK 版本号。
    public static let version = "1.0.2"

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
    /// 在 `decrypt` 闭包内完成（如业务方的 `decodeAes(data, ungzip: true)`）。
    ///
    /// 匹配：按注册顺序，contentType（大小写不敏感）包含 `contentTypeKey` 即命中，
    /// 首个命中生效；未命中返回 nil，SDK 走既有 fallback（bodyBase64 → UTF-8）。
    /// 可注册多个 codec（不同 contentTypeKey）。
    ///
    /// - Parameters:
    ///   - contentTypeKey: contentType 匹配键，例如 "xcp"。
    ///   - compression: 压缩方式（SDK 在 responseEncrypt 前执行）。
    ///   - responseEncrypt: 响应体业务加密闭包，入参为 SDK 压缩后的字节，返回密文（nil 表示失败）。
    ///   - responseDecrypt: 响应体业务解密闭包，入参为原始密文，返回明文（nil 表示失败）。
    ///   - requestEncrypt: 请求体业务加密闭包（可选，预留）。请求体回放/改写场景使用；
    ///     当前 Mock 不改写请求体，传 nil（默认）即可。
    ///   - requestDecrypt: 请求体业务解密闭包（可选）。不同 App 的请求体/响应体
    ///     编码可能不对称（如响应体 gzip+AES、请求体仅 AES）；请求体与响应体编码
    ///     不对称时传此闭包单独解请求体。传 nil（默认）表示请求体不解码
    ///     （回退 `[binary N bytes]` 占位）——兼容只注册响应体编解码的旧接入。
    public static func registerBinaryCodec(
        for contentTypeKey: String,
        compression: BinaryCompression,
        responseEncrypt: @escaping @Sendable (Data) -> Data?,
        responseDecrypt: @escaping @Sendable (Data) -> Data?,
        requestEncrypt: (@Sendable (Data) -> Data?)? = nil,
        requestDecrypt: (@Sendable (Data) -> Data?)? = nil
    ) {
        TrafficCaptureController.shared.registerBinaryCodec(
            for: contentTypeKey,
            compression: compression,
            responseEncrypt: responseEncrypt,
            responseDecrypt: responseDecrypt,
            requestEncrypt: requestEncrypt,
            requestDecrypt: requestDecrypt
        )
    }

    /// 启动连接层：生成/读取 did → 注册设备 → 周期心跳 → 会话状态推导。
    /// - Parameters:
    ///   - server: 服务器 base URL（形如 `http://host:4290/api/v1`）。
    ///   - appID: App 标识，默认取 Bundle ID；SDK 生成并持久化 did 的作用域。
    ///   - did: 业务方提供的设备 ID（如业务方 Keychain deviceID）。传入后 SDK 不再
    ///     自行生成 did，直接用它——保证 did 与调试页展示一致、Clean Build 不漂移。
    ///     传 nil 则回退到 SDK 内部 DIDStore 生成。
    ///   - appVersion: App 版本，默认取 CFBundleShortVersionString。
    ///   - logHandler: 日志回调（可选；默认走 OSLog）。
    /// 幂等：已在运行则忽略。
    public static func start(server: URL,
                             appID: String? = nil,
                             did: String? = nil,
                             appVersion: String? = nil,
                             logHandler: (@Sendable (String) -> Void)? = nil) {
        ConnectionController.shared.start(
            server: server,
            appID: appID ?? Self.bundleID,
            externalDID: did,
            appVersion: appVersion ?? Self.bundleVersion,
            appName: Self.appName,
            sdkVersion: version,
            osVersion: Self.osVersion,
            logHandler: logHandler
        )
    }

    /// 无参启动（M9.2 扫码连接）：读取持久化服务器地址直连；未配置 → `.unconfigured`
    /// （不发起网络，等待扫码）。appID 固定取 Bundle ID（ServerAddressStore 键与 did
    /// 作用域一致）。已注册设备重启免扫码（A2）。
    /// - Parameter did: 业务方设备 ID（如业务方 Keychain deviceID，M7.2.4 一致性要求）。
    ///   传 nil 则回退 SDK 内部 DIDStore。无论直连还是扫码注册，did 均以此为准（D7）。
    public static func start(did: String? = nil) {
        if let url = ServerAddressStore.load(forApp: bundleID) {
            start(server: url, did: did)
        } else {
            ConnectionController.shared.startUnconfigured(
                appID: bundleID,
                externalDID: did,
                appVersion: bundleVersion,
                appName: Self.appName,
                sdkVersion: version,
                osVersion: osVersion)
        }
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

    // MARK: - M9.2 扫码连接（免写死服务器地址）

    /// 扫码连接错误分类（M9.2）。
    public enum ConnectByScanError: Error, Equatable, Sendable {
        /// 用户关闭扫码界面。
        case cancelled
        /// 相机不可用（模拟器/无摄像头）。
        case cameraUnavailable
        /// 用户拒绝相机权限。
        case cameraDenied
        /// 二维码内容不是合法 mocknetpack 连接协议。
        case invalidPayload
        /// 二维码 appID 与当前 App 不匹配（防错扫）。
        case appMismatch
        /// 配对令牌无效/过期（服务端 403 pairing_token_invalid → 提示「二维码已过期，请刷新」）。
        case tokenInvalid
        /// 服务器不可达 / 注册失败（非 403）。
        case unreachable
    }

    /// 已持久化的服务器地址（`start()` 无参直连用；扫码成功后写入；Debug 页展示用）。
    public static var savedServerURL: URL? {
        ServerAddressStore.load(forApp: bundleID)
    }

    /// 清除已持久化的服务器地址（Debug 页「重置服务器」→ 回到 `.unconfigured`）。
    public static func resetServer() {
        ServerAddressStore.clear(forApp: bundleID)
    }

    /// 扫码连接（M9.2，iOS）：**先请求相机权限（预授权，M11）** → 调起相机扫码 →
    /// 解析校验 → 携带配对令牌注册（一次完成可达性 + 令牌校验）→ 成功则持久化地址并启动连接。
    /// 已连接时（D6）直接切换到新服务器，旧服务器设备记录保留、心跳超时自然离线。
    /// 失败（R1.6）不覆盖已保存地址。
    /// - Parameters:
    ///   - presenter: 用于 present 扫码界面的视图控制器（Debug 页）。
    ///   - completion: 主线程回调（成功 / 分类错误）。
    #if canImport(UIKit)
    public static func connectByScan(from presenter: UIViewController,
                                     completion: @escaping @Sendable (Result<Void, ConnectByScanError>) -> Void) {
        Task { @MainActor in
            // M11-fix：进入相机页前先请求相机权限（授权弹窗与扫码页解耦）：
            // 首次授权后 AVFoundation 授权状态传播有延迟，若在扫码页内授权并立即
            // 建 session 易误判"相机不可用"。此处预授权 + 短暂等待传播就绪，再 present。
            let granted: Bool
            do {
                granted = try await QRScannerViewController.requestCameraAccess()
            } catch {
                granted = false
            }
            guard granted else {
                completion(.failure(.cameraDenied))
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)

            // 扫码控制器为 @MainActor 隔离，须在 MainActor 上构造。
            let scanner = QRScannerViewController(presentingFrom: presenter)
            let result = await Self.connectByScan(scanner: scanner)
            // M9.3-fix：扫码流程结束（成功/失败）兜底收起扫码面板，防 dismiss 竞态静默失败。
            scanner.dismissIfPresented()
            completion(result)
        }
    }
    #endif

    /// 扫码连接核心（M9.2）：扫码 → 解析 → 令牌注册 → 持久化 + 启动。测试注入 mock scanner。
    @MainActor
    static func connectByScan(scanner: QRScanProviding,
                              makeClient: (@Sendable (URL) -> ConnectionClient)? = nil) async -> Result<Void, ConnectByScanError> {
        // 1) 扫码。
        let raw: String?
        do {
            raw = try await scanner.scanQRCode()
        } catch QRScanError.cameraDenied {
            return .failure(.cameraDenied)
        } catch QRScanError.cameraUnavailable {
            return .failure(.cameraUnavailable)
        } catch {
            return .failure(.cameraUnavailable)
        }
        guard let raw else { return .failure(.cancelled) }

        // 2) 解析校验（协议/版本/服务器/appID 匹配/令牌）。
        let payload: QRConnectPayload
        switch QRConnectParser.parse(raw, expectedAppID: bundleID) {
        case .success(let p):
            payload = p
        case .failure(.appMismatch):
            return .failure(.appMismatch)
        case .failure:
            return .failure(.invalidPayload)
        }

        // 3) 本地网络可达性探测（M11-2）：iOS 首次访问局域网地址会触发「本地网络」
        // 权限弹窗，未授权期间连接被系统拒绝——若直接注册，首次扫码必然失败
        // （unreachable）需二次扫码。先发轻量探测（收到任何 HTTP 响应即视为连通，
        // 传输层错误自动重试给授权留时间）；仍失败返回 unreachable。
        let client = makeClient?(payload.serverURL) ?? ConnectionClient(baseURL: payload.serverURL)
        guard await Self.probeLocalNetwork(client: client) else {
            return .failure(.unreachable)
        }

        // 4) 令牌注册（可达性 + 令牌校验二合一）。did 复用（D7）：与启动注册同一 did。
        let appID = ConnectionController.shared.resolvedAppID ?? bundleID
        let did = ConnectionController.shared.did ?? DIDStore.did(forApp: appID)
        let req = RegisterDeviceRequest(
            app: appID,
            did: did,
            platform: "ios",
            osVersion: osVersion,
            sdkVersion: version,
            appVersion: bundleVersion,
            appName: Self.appName,
            pairingToken: payload.token,
            deviceName: nil
        )
        do {
            _ = try await client.post("devices/register", body: req, as: RegisterDeviceResponse.self)
        } catch ConnectionClientError.httpStatus(403) {
            return .failure(.tokenInvalid)
        } catch {
            return .failure(.unreachable)
        }

        // 4) 成功：D6 切换（stop 幂等）→ 持久化地址 → 启动连接（免扫码直连 A2）。
        ConnectionController.shared.stop()
        ServerAddressStore.save(payload.serverURL, forApp: appID)
        ConnectionController.shared.start(
            server: payload.serverURL,
            appID: appID,
            externalDID: did,
            appVersion: bundleVersion,
            appName: Self.appName,
            sdkVersion: version,
            osVersion: osVersion)
        return .success(())
    }

    /// 本地网络可达性探测（M11-2）：对服务器地址发轻量 GET（必然 404 路径），
    /// 收到任何 HTTP 响应即视为网络连通且 iOS「本地网络」权限已就绪；传输层
    /// 错误（权限未授权/网络不可达）按固定间隔自动重试，给首次授权弹窗留出
    /// 操作时间。重试上限内任意一次成功即返回 true。
    /// - Parameters:
    ///   - client: 指向扫码 payload 服务器地址的连接客户端。
    ///   - attempts: 最大尝试次数。
    ///   - interval: 失败重试间隔（秒）。
    /// - Returns: 探测是否成功。
    private static func probeLocalNetwork(client: ConnectionClient,
                                          attempts: Int = 4,
                                          interval: TimeInterval = 1.5) async -> Bool {
        for attempt in 0..<attempts {
            do {
                try await client.probe()
                return true
            } catch {
                if attempt < attempts - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
        }
        return false
    }

    // MARK: - 系统信息

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown.app"
    }

    private static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// App 显示名（v0.9.0）：CFBundleDisplayName（如接入方 App 的显示名），回退 CFBundleName（工程名）。
    /// 随注册请求上报 appName，Web 设备列表优先展示显示名而非 bundle id。
    private static var appName: String? {
        let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return display ?? name
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
