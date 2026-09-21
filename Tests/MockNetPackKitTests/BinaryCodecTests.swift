import XCTest
@testable import MockNetPackKit
import zlib

/// M6.2：registerBinaryCodec 编解码器路径——
/// gzip 对称 / UTF-8 往返 / contentType 匹配（大小写不敏感、注册顺序）/
/// .none 不压缩 / 失败回退 / 端到端回放。
final class BinaryCodecTests: XCTestCase {

    private let serverURL = URL(string: "http://mock.local/api/v1")!
    private let appID = "com.test.app"
    private let did = "did-codec"

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil
        MockRuleController.shared.reset()
        TrafficCaptureController.shared.resetBinaryCodecs()

        let controller = TrafficCaptureController.shared
        let uploadConfig = URLSessionConfiguration.ephemeral
        uploadConfig.protocolClasses = [MockURLProtocol.self]
        controller.clientFactory = { [uploadConfig] url in
            ConnectionClient(configuration: uploadConfig, baseURL: url)
        }
        controller.flushInterval = 0.1
    }

    override func tearDown() {
        TrafficCaptureController.shared.stop()
        TrafficCaptureController.shared.resetBinaryCodecs()
        MockRuleController.shared.reset()
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedRequests.removeAll()
        MockNetPackURLProtocol.forwardingConfiguration = nil
        super.tearDown()
    }

    /// 配置业务请求走 MockNetPackURLProtocol。
    private func businessSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNetPackURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - 回放链路（encrypt）

    /// .gzip：SDK 先 gzip 压缩再调 encrypt；输出为标准 gzip（1f 8b），可解回原文。
    func testReplayGzipEncryptReceivesCompressedData() throws {
        let captured = Box<Data?>(nil)
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .gzip,
            responseEncrypt: { data in captured.value = data; return data },
            responseDecrypt: { $0 }
        )
        let text = #"{"name":"沈淮行"}"#
        let encoded = TrafficCaptureController.shared.bodyEncoder?(text, "application/x-xcp")
        XCTAssertNotNil(encoded)
        let bytes = [UInt8](encoded!)
        XCTAssertEqual(bytes[0], 0x1f, "标准 gzip magic 1")
        XCTAssertEqual(bytes[1], 0x8b, "标准 gzip magic 2")
        XCTAssertEqual(captured.value, encoded, "encrypt 闭包应收到 SDK 压缩后的字节")
        XCTAssertEqual(gunzip(encoded!), Data(text.utf8), "gzip 输出应可解回原文")
    }

    /// .none：不压缩，encrypt 直接收到 UTF-8 原文。
    func testReplayNoneSkipsCompression() throws {
        let captured = Box<Data?>(nil)
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .none,
            responseEncrypt: { data in captured.value = data; return data },
            responseDecrypt: { $0 }
        )
        let text = #"{"plain":true}"#
        let encoded = TrafficCaptureController.shared.bodyEncoder?(text, "application/x-xcp")
        XCTAssertEqual(encoded, Data(text.utf8))
        XCTAssertEqual(captured.value, Data(text.utf8), ".none 时 encrypt 应收到未压缩字节")
    }

    // MARK: - 展示链路（decrypt → UTF-8）

    /// decrypt 闭包解出明文后，SDK 转 UTF-8 文本（对应 KK decodeAes(ungzip: true)）。
    func testDecodePathDecryptThenUTF8() throws {
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .gzip,
            responseEncrypt: { $0 },
            responseDecrypt: { gunzip($0) }
        )
        let text = #"{"user":"张三","age":18}"#
        let gz = Data(text.utf8).gzipCompressed()!
        let decoded = TrafficCaptureController.shared.bodyDecoder?(gz, "application/x-xcp")
        XCTAssertEqual(decoded, text, "decrypt 解出明文后应转成可读 UTF-8 文本")
    }

    // MARK: - contentType 匹配

    /// 大小写不敏感匹配；不匹配时返回 nil（SDK 走既有 fallback）。
    func testContentTypeMatchCaseInsensitiveAndUnmatchedNil() throws {
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .none,
            responseEncrypt: { $0 },
            responseDecrypt: { $0 }
        )
        XCTAssertEqual(TrafficCaptureController.shared.bodyEncoder?("t", "Application/X-XCP"), Data("t".utf8))
        XCTAssertNil(TrafficCaptureController.shared.bodyEncoder?("t", "application/json"))
        XCTAssertEqual(TrafficCaptureController.shared.bodyDecoder?(Data("t".utf8), "APPLICATION/XCP"), "t")
        XCTAssertNil(TrafficCaptureController.shared.bodyDecoder?(Data("t".utf8), "text/plain"))
    }

    /// 多 codec：按注册顺序，首个 contentType 包含 key 的生效。
    func testMultipleCodecsFirstRegisteredWins() throws {
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .none,
            responseEncrypt: { Data("1:".utf8) + $0 },
            responseDecrypt: { $0 }
        )
        MockNetPackKit.registerBinaryCodec(
            for: "kkbin",
            compression: .none,
            responseEncrypt: { Data("2:".utf8) + $0 },
            responseDecrypt: { $0 }
        )
        XCTAssertEqual(TrafficCaptureController.shared.bodyEncoder?("t", "application/xcp"), Data("1:t".utf8))
        XCTAssertEqual(TrafficCaptureController.shared.bodyEncoder?("t", "application/kkbin"), Data("2:t".utf8))
        // 同时包含两个 key → 先注册的 "xcp" 生效。
        XCTAssertEqual(TrafficCaptureController.shared.bodyEncoder?("t", "application/xcp+kkbin"), Data("1:t".utf8))
        XCTAssertNil(TrafficCaptureController.shared.bodyEncoder?("t", "application/octet-stream"))
    }

    // MARK: - 失败与清理

    /// decrypt 失败返回 nil → SDK 返回 nil（URLProtocol 回退 [binary N bytes] 占位）。
    func testDecryptFailureReturnsNil() throws {
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .gzip,
            responseEncrypt: { $0 },
            responseDecrypt: { _ in nil }
        )
        XCTAssertNil(TrafficCaptureController.shared.bodyDecoder?(Data([0x01, 0x02]), "application/x-xcp"))
    }

    /// resetBinaryCodecs 清空注册与 dispatch 槽位。
    func testResetClearsCodecs() throws {
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .none,
            responseEncrypt: { $0 },
            responseDecrypt: { $0 }
        )
        XCTAssertNotNil(TrafficCaptureController.shared.bodyEncoder)
        TrafficCaptureController.shared.resetBinaryCodecs()
        XCTAssertNil(TrafficCaptureController.shared.bodyEncoder)
        XCTAssertNil(TrafficCaptureController.shared.bodyDecoder)
    }

    // MARK: - 端到端

    /// registerBinaryCodec 注册后，URLProtocol 回放编辑过的文本输出 gzip 二进制。
    func testEndToEndReplayServesGzipForEditedXcpRule() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-codec-e2e")

        let captured = Box<Data?>(nil)
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .gzip,
            responseEncrypt: { data in captured.value = data; return data },
            responseDecrypt: { $0 }
        )
        let text = #"{"name":"编辑后的回包"}"#
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r1", method: "POST", path: "/api/xcp",
            response: MockResponse(statusCode: 200,
                headers: ["Content-Type": "application/x-xcp"],
                body: text),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            XCTFail("命中 Mock 不应转发: \(request.url?.absoluteString ?? "")")
            return jsonResponse(200, json: ["real": true])
        }

        var req = URLRequest(url: URL(string: "https://api.example.com/api/xcp")!)
        req.httpMethod = "POST"
        let received = Box<Data?>(nil)
        let exp = expectation(description: "codec mock")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        let served = try XCTUnwrap(received.value)
        XCTAssertEqual([UInt8](served)[0], 0x1f)
        XCTAssertEqual([UInt8](served)[1], 0x8b)
        XCTAssertEqual(gunzip(served), Data(text.utf8), "端到端回放应输出可解回原文的标准 gzip")
        XCTAssertEqual(captured.value, served, "encrypt 闭包收到的应正是回放的 gzip 字节")
    }

    /// 未编辑二进制规则（body 为占位文本 + bodyBase64 原始字节）：回放必须输出
    /// 原始字节，encrypt 闭包不应被调用（M7 顺序调整，bodyBase64 优先于 encoder）。
    func testEndToEndReplayServesRawBytesForUneditedBinaryRule() throws {
        let controller = TrafficCaptureController.shared
        controller.start(serverURL: serverURL, appID: appID, did: did)
        controller.updateSession(capturing: true, sessionID: "sess-codec-raw")

        let rawBytes = Data([0x1f, 0x8b, 0x08, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        let encryptCalled = Box<Bool>(false)
        MockNetPackKit.registerBinaryCodec(
            for: "xcp",
            compression: .gzip,
            responseEncrypt: { data in encryptCalled.value = true; return data },
            responseDecrypt: { $0 }
        )
        MockRuleController.shared.applyForTesting(rules: [MockRule(
            id: "r-raw", method: "POST", path: "/api/xcp-raw",
            response: MockResponse(statusCode: 200,
                headers: ["Content-Type": "application/x-xcp"],
                body: "[binary 11 bytes]",
                bodyBase64: rawBytes.base64EncodedString()),
            enabled: true, effective: true)], version: 1)

        let forwardConfig = URLSessionConfiguration.ephemeral
        forwardConfig.protocolClasses = [MockURLProtocol.self]
        MockNetPackURLProtocol.forwardingConfiguration = forwardConfig
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/traffic") == true {
                return jsonResponse(202, json: ["accepted": true, "count": 1])
            }
            XCTFail("命中 Mock 不应转发: \(request.url?.absoluteString ?? "")")
            return jsonResponse(200, json: ["real": true])
        }

        var req = URLRequest(url: URL(string: "https://api.example.com/api/xcp-raw")!)
        req.httpMethod = "POST"
        let received = Box<Data?>(nil)
        let exp = expectation(description: "codec raw mock")
        businessSession().dataTask(with: req) { data, _, _ in
            received.value = data
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 3)

        let served = try XCTUnwrap(received.value)
        XCTAssertEqual(served, rawBytes, "未编辑二进制规则应回放原始字节")
        XCTAssertFalse(encryptCalled.value, "未编辑规则不应触发 encoder")
    }

    // MARK: - 辅助

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }
}

/// 测试辅助：标准 gzip 解压（独立 zlib 实现，用于验证 SDK gzip 输出格式）。
func gunzip(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    let input = [UInt8](data)
    var stream = z_stream()
    let initResult = inflateInit2_(
        &stream,
        MAX_WBITS + 16,
        "1.2.12", Int32(MemoryLayout<z_stream>.size)
    )
    guard initResult == Z_OK else { return nil }
    defer { inflateEnd(&stream) }

    var output = Data(capacity: input.count * 2)
    var outBuffer = [UInt8](repeating: 0, count: 16384)
    var failed = false

    input.withUnsafeBufferPointer { inputPtr in
        stream.next_in = UnsafeMutablePointer(mutating: inputPtr.baseAddress)
        stream.avail_in = uInt(inputPtr.count)
        repeat {
            stream.next_out = outBuffer.withUnsafeMutableBytes {
                $0.bindMemory(to: Bytef.self).baseAddress
            }
            stream.avail_out = uInt(outBuffer.count)
            let status = inflate(&stream, Z_FINISH)
            guard status == Z_OK || status == Z_STREAM_END else {
                failed = true
                return
            }
            let produced = outBuffer.count - Int(stream.avail_out)
            output.append(outBuffer, count: produced)
            if status == Z_STREAM_END { break }
        } while true
    }
    return failed ? nil : output
}
