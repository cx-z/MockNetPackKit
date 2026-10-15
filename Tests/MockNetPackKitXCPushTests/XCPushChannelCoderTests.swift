import XCTest
@testable import MockNetPackKit
#if canImport(MockNetPackKitXCPushObjC)
@testable import MockNetPackKitXCPushObjC
#endif
@testable import MockNetPackKitXCPush

/// L5.6：XCPush 内置 coder——动态解码（测试环境无 FDSocketService/Sync 类，
/// 覆盖 fallback JSON 直解与不可解降级；Sync protobuf 路径由 UI 验收在真机验证）。
final class XCPushChannelCoderTests: XCTestCase {

    private let coder = XCPushChannelCoder()

    func testDecodesPlainJSONPayload() {
        // bizType=2 push 状态包：raw 直接是 JSON。
        let raw = Data("{\"to_mid\":302139673,\"type\":500,\"ct\":1791948840}".utf8)
        let text = coder.decode(channelId: "xcpush_tcp", raw: raw, context: [:])
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("\"to_mid\""), "plain JSON must be decoded to text")
        XCTAssertTrue(text!.contains("302139673"))
    }

    func testReturnsNilForBinaryGarbage() {
        // 非 JSON、且 Sync 类在测试环境不存在 → 降级 nil（SDK 保留 base64）。
        var bytes: [UInt8] = [0x0a, 0x09, 0x33, 0x30, 0x32, 0x31, 0x33, 0x39, 0x36, 0x37, 0x33, 0x12, 0x01, 0x11]
        let raw = Data(bytes)
        XCTAssertNil(coder.decode(channelId: "xcpush_tcp", raw: raw, context: [:]),
                     "undecodable binary must return nil (fallback base64)")
    }

    func testReturnsNilForEmptyPayload() {
        let raw = Data()
        XCTAssertNil(coder.decode(channelId: "xcpush_tcp", raw: raw, context: [:]))
    }

    func testObjCFunctionFallbackJSONDirectly() {
        // 直接验证 ObjC 函数：JSON 字节 → pretty 文本。
        #if canImport(MockNetPackKitObjC)
        let raw = Data("{\"a\":1,\"b\":\"x\"}".utf8)
        let text = MNPXCPushDecodeToJSON(raw)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("\"a\" : 1") || text!.contains("\"a\":1"), "pretty JSON output")
        #endif
    }
}
