import XCTest
@testable import MockNetPackKit

final class QRConnectParserTests: XCTestCase {

    private let expectedApp = "com.test.app"

    /// 构造符合协议的二维码文本（Web 端同款编码：base64url 去 padding）。
    private func qr(server: String = "http://mock.local/api/v1",
                    appID: String = "com.test.app",
                    token: String = "tok-1",
                    version: String = "1") -> String {
        let u = Data(server.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "mocknetpack://connect?v=\(version)&u=\(u)&a=\(appID)&t=\(token)"
    }

    func testParse_ValidPayload() throws {
        let result = QRConnectParser.parse(qr(), expectedAppID: expectedApp)
        let payload = try result.get()
        XCTAssertEqual(payload.serverURL.absoluteString, "http://mock.local/api/v1")
        XCTAssertEqual(payload.appID, expectedApp)
        XCTAssertEqual(payload.token, "tok-1")
    }

    func testParse_Base64URLWithDashUnderscore() throws {
        // 含 - _ 的 base64url（无 = 号 padding），Web 端标准编码。
        let server = "https://example.com/api/v1"
        let result = QRConnectParser.parse(qr(server: server), expectedAppID: expectedApp)
        XCTAssertEqual(try result.get().serverURL.absoluteString, server)
    }

    func testParse_WrongScheme_Fails() {
        let raw = "https://connect?v=1&u=aHR0cDovL21vY2subG9jYWwvYXBpL3Yx&a=\(expectedApp)&t=tok"
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.notMockNetPack))
    }

    func testParse_WrongHost_Fails() {
        let raw = "mocknetpack://other?v=1&u=aHR0cDovL21vY2subG9jYWwvYXBpL3Yx&a=\(expectedApp)&t=tok"
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.notMockNetPack))
    }

    func testParse_UnsupportedVersion_Fails() {
        XCTAssertEqual(QRConnectParser.parse(qr(version: "2"), expectedAppID: expectedApp),
                       .failure(.unsupportedVersion))
    }

    func testParse_MissingVersion_Fails() {
        let raw = "mocknetpack://connect?u=aHR0cDovL21vY2subG9jYWwvYXBpL3Yx&a=\(expectedApp)&t=tok"
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.unsupportedVersion))
    }

    func testParse_MissingServer_Fails() {
        let raw = "mocknetpack://connect?v=1&a=\(expectedApp)&t=tok"
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.invalidServer))
    }

    func testParse_ServerNotBase64_Fails() {
        let raw = "mocknetpack://connect?v=1&u=!!!&a=\(expectedApp)&t=tok"
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.invalidServer))
    }

    func testParse_ServerNotHttp_Fails() {
        let server = "ftp://files.local/share"
        XCTAssertEqual(QRConnectParser.parse(qr(server: server), expectedAppID: expectedApp),
                       .failure(.invalidServer))
    }

    func testParse_ServerEmptyHost_Fails() {
        let server = "http://"
        XCTAssertEqual(QRConnectParser.parse(qr(server: server), expectedAppID: expectedApp),
                       .failure(.invalidServer))
    }

    func testParse_MissingAppID_Fails() {
        let raw = "mocknetpack://connect?v=1&u=aHR0cDovL21vY2subG9jYWwvYXBpL3Yx&t=tok"
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.missingAppID))
    }

    func testParse_AppMismatch_Fails() {
        XCTAssertEqual(QRConnectParser.parse(qr(appID: "com.other.app"), expectedAppID: expectedApp),
                       .failure(.appMismatch))
    }

    func testParse_MissingToken_Fails() {
        let raw = "mocknetpack://connect?v=1&u=aHR0cDovL21vY2subG9jYWwvYXBpL3Yx&a=\(expectedApp)"
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.missingToken))
    }

    func testParse_EmptyToken_Fails() {
        let raw = "mocknetpack://connect?v=1&u=aHR0cDovL21vY2subG9jYWwvYXBpL3Yx&a=\(expectedApp)&t="
        XCTAssertEqual(QRConnectParser.parse(raw, expectedAppID: expectedApp), .failure(.missingToken))
    }
}
