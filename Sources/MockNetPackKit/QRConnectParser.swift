import Foundation

/// 扫码连接二维码载荷（M9，契约 v0.8.0）。
///
/// 二维码格式（D4）：`mocknetpack://connect?v=1&u=<base64url(server)>&a=<appID>&t=<token>`
/// - `u`：Web 同源服务器地址（`${location.origin}/api/v1`），base64url 编码；
/// - `a`：appID（必须与当前 App 匹配，防错扫）；
/// - `t`：配对令牌（10 分钟有效，D5）。
///
/// did 不在二维码内（D6 澄清）：did 由设备本地持有（DIDStore / IntegratingApp Keychain），
/// 二维码只回答「连哪个服务器、以谁的身份注册」。
struct QRConnectPayload: Equatable {
    /// 服务器 base URL（如 `http://host:4290/api/v1`）。
    let serverURL: URL
    /// 二维码声明的 appID。
    let appID: String
    /// 配对令牌。
    let token: String
}

/// 二维码解析错误分类（M9.2）。
enum QRConnectParseError: Error, Equatable {
    /// scheme/host 不是 mocknetpack://connect。
    case notMockNetPack
    /// 协议版本不支持（v != 1）。
    case unsupportedVersion
    /// u 缺失 / 解码失败 / 非 http(s) / host 为空。
    case invalidServer
    /// appID 缺失。
    case missingAppID
    /// 二维码 appID 与当前 App 不匹配（防错扫）。
    case appMismatch
    /// 令牌缺失。
    case missingToken
}

/// 扫码二维码解析器（M9.2）。
enum QRConnectParser {

    /// 解析并校验二维码内容。
    /// - Parameters:
    ///   - raw: 二维码原始文本。
    ///   - expectedAppID: 当前 App 标识（Bundle ID）；二维码 appID 必须与之匹配。
    static func parse(_ raw: String, expectedAppID: String) -> Result<QRConnectPayload, QRConnectParseError> {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "mocknetpack",
              comps.host?.lowercased() == "connect" else {
            return .failure(.notMockNetPack)
        }
        let query = comps.queryItems ?? []

        // 版本（v=1）。
        guard query.first(where: { $0.name == "v" })?.value == "1" else {
            return .failure(.unsupportedVersion)
        }

        // 服务器地址（u = base64url）。
        guard let uRaw = query.first(where: { $0.name == "u" })?.value,
              let uData = base64URLDecode(uRaw),
              let serverRaw = String(data: uData, encoding: .utf8),
              let serverURL = URL(string: serverRaw),
              let scheme = serverURL.scheme, (scheme == "http" || scheme == "https"),
              let host = serverURL.host, !host.isEmpty else {
            return .failure(.invalidServer)
        }

        // appID（a）——必须与当前 App 匹配。
        guard let appID = query.first(where: { $0.name == "a" })?.value, !appID.isEmpty else {
            return .failure(.missingAppID)
        }
        guard appID == expectedAppID else {
            return .failure(.appMismatch)
        }

        // 配对令牌（t）。
        guard let token = query.first(where: { $0.name == "t" })?.value, !token.isEmpty else {
            return .failure(.missingToken)
        }

        return .success(QRConnectPayload(serverURL: serverURL, appID: appID, token: token))
    }

    /// base64url 解码（RFC 4648 §5：- _ 替代 + /，去 padding）。
    private static func base64URLDecode(_ value: String) -> Data? {
        var b64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 {
            b64.append("=")
        }
        return Data(base64Encoded: b64)
    }
}
