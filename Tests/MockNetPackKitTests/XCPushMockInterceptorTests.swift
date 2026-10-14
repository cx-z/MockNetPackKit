//
//  XCPushMockInterceptorTests.swift
//  MockNetPackKitTests
//
//  L5.3 验收：push mock 拦截钩子（Debug-only）。
//
//  覆盖（对齐确认清单验收标准）：
//  1. 默认无规则 / 规则停用 → 全部放行（行为与 L5.2 一致，零影响）；
//  2. 命中替换 bizData → 采集记录与原 delegate 均见替换后数据（与业务一致）；
//  3. 命中替换 bizData + 新 msgId → msgId 同步更新，采集记录为新 msgId；
//  4. 新 msgId 自然进入采集去重表（规避 KK 判重丢弃的配套行为）；
//  5. 未命中（provider 返回 nil）→ 原样放行。
//
//  基座复用：FakeXCPushSocket（L5.1）+ FakeTalk（L5.2，internal 跨文件可见）；
//  ObjC 消息派发模拟 helper 与本文件私有副本一致。
//

import Foundation
import XCTest
import ObjectiveC
import Darwin
import MockNetPackKitObjC
@testable import MockNetPackKit

/// 原 delegate：记录收包 talk（验证 mock 替换后业务侧实际收到的数据）。
@objc final class ReadCaptureDelegate: NSObject {
    var lastTalk: AnyObject?
    var lastTag: Int?
    @objc func asyncSocket(_ sock: AnyObject, didReadTalk talk: AnyObject, withTag tag: Int) {
        lastTalk = talk
        lastTag = tag
    }
}

// MARK: - ObjC 消息派发模拟（swizzle 生效路径；与 XCPushLongConnRecorderTests 同构）

private func dlsymMsgSend<T>(_ type: T.Type) -> T {
    let handle = UnsafeMutableRawPointer(bitPattern: -2)!   // RTLD_DEFAULT
    guard let sym = dlsym(handle, "objc_msgSend") else {
        fatalError("objc_msgSend symbol not found")
    }
    return unsafeBitCast(sym, to: T.self)
}

private func msgSendSetDelegate(_ socket: AnyObject, _ delegate: AnyObject?) {
    _ = socket.perform(NSSelectorFromString("setDelegate:"), with: delegate)
}

private func msgSendConnectToHost(_ socket: AnyObject, _ host: String, _ port: UInt16) {
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, UInt16) -> Void
    let fn: Fn = dlsymMsgSend(Fn.self)
    fn(socket, NSSelectorFromString("connectToHost:onPort:"), host as NSString, port)
}

final class XCPushMockInterceptorTests: XCTestCase {

    private var recorder: XCPushLongConnRecorder { .shared }
    private var collected: [LongConnectionRecordInput] = []
    private var fakeSocket: FakeXCPushSocket!
    private var originalDelegate: ReadCaptureDelegate!

    override func setUp() {
        super.setUp()
        collected = []
        recorder.recordSink = { [weak self] in self?.collected.append($0) }
        fakeSocket = FakeXCPushSocket()
        originalDelegate = ReadCaptureDelegate()
        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")
        msgSendSetDelegate(fakeSocket, originalDelegate)
        msgSendConnectToHost(fakeSocket, "router.mock", 9001)
        XCPushMockInterceptor.shared.ruleProvider = nil   // 默认放行
        collected.removeAll()
    }

    override func tearDown() {
        XCPushMockInterceptor.shared.ruleProvider = nil
        recorder.recordSink = { MockNetPackKit.recordLongConnection($0) }
        super.tearDown()
    }

    // MARK: - 验收 1：默认无规则 / 停用 → 放行（零影响）

    func testNoRulePassesThrough() {
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 10
        talk.bizData = Data("orig".utf8)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.payloadBase64, Data("orig".utf8).base64EncodedString())
        XCTAssertEqual(packet?.msgId, "10")
        XCTAssertEqual(originalDelegate.lastTalk as? FakeTalk === talk ? true : false, true,
                       "无规则时原 delegate 收到原始 talk")
    }

    func testDisabledRulePassesThrough() {
        XCPushMockInterceptor.shared.ruleProvider = { _, _, _, _ in
            XCTFail("停用后不应再查询规则")
            return nil
        }
        // 显式停用（置 nil 覆盖上一条 provider）
        XCPushMockInterceptor.shared.ruleProvider = nil

        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 11
        talk.bizData = Data("orig".utf8)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.payloadBase64, Data("orig".utf8).base64EncodedString())
    }

    // MARK: - 验收 2：命中替换 bizData

    func testHitReplacesBizData() {
        XCPushMockInterceptor.shared.ruleProvider = { _, _, _, _ in
            .replace(payload: Data("mock-payload".utf8), newMsgId: nil)
        }
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 10
        talk.bizData = Data("orig".utf8)
        driveRead(talk)

        // 采集记录为替换后数据（与业务实际收到一致）
        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.payloadBase64, Data("mock-payload".utf8).base64EncodedString())
        XCTAssertEqual(packet?.msgId, "10", "未指定新 msgId 时保留原 msgId")

        // 原 delegate 收到替换后 talk
        let receivedBizData = originalDelegate.lastTalk?.value(forKey: "bizData") as? Data
        XCTAssertEqual(receivedBizData, Data("mock-payload".utf8), "业务侧无感收到 mock 数据")
    }

    // MARK: - 验收 3：命中替换 bizData + 新 msgId

    func testHitReplacesMsgId() {
        XCPushMockInterceptor.shared.ruleProvider = { _, _, _, _ in
            .replace(payload: Data("m".utf8), newMsgId: 200)
        }
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 10
        talk.bizData = Data("orig".utf8)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.msgId, "200", "规则携带新 msgId 时采集记录同步为新值")
        XCTAssertEqual(packet?.payloadBase64, Data("m".utf8).base64EncodedString())

        let receivedMsgId = (originalDelegate.lastTalk?.value(forKey: "msgId") as? NSNumber)?.uint64Value
        XCTAssertEqual(receivedMsgId, 200, "原 delegate 收到新 msgId（规避 KK 判重丢弃）")
    }

    // MARK: - 验收 4：新 msgId 自然进入采集去重表

    func testNewMsgIdEntersDedupTable() {
        XCPushMockInterceptor.shared.ruleProvider = { _, _, _, _ in
            .replace(payload: Data("m".utf8), newMsgId: 200)
        }
        let mock = FakeTalk()
        mock.type = 7
        mock.msgId = 10
        mock.bizData = Data("orig".utf8)
        driveRead(mock)

        // 服务器后续重发同 msgId（200）真实包 → 采集判重（去重表已含新 msgId）
        XCPushMockInterceptor.shared.ruleProvider = nil
        let real = FakeTalk()
        real.type = 7
        real.msgId = 200
        real.bizData = Data("real".utf8)
        driveRead(real)

        let packets = collected.filter { $0.eventType == .packet }
        XCTAssertEqual(packets.count, 2)
        XCTAssertTrue(packets[1].duplicate, "mock 新 msgId 已进入去重表，同 msgId 真实包被判重")
    }

    // MARK: - 验收 5：未命中 → 原样放行

    func testMissPassesThrough() {
        XCPushMockInterceptor.shared.ruleProvider = { _, _, _, _ in
            nil   // 未命中
        }
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 12
        talk.bizData = Data("orig".utf8)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.payloadBase64, Data("orig".utf8).base64EncodedString())
        XCTAssertEqual(packet?.msgId, "12")
        let receivedBizData = originalDelegate.lastTalk?.value(forKey: "bizData") as? Data
        XCTAssertEqual(receivedBizData, Data("orig".utf8), "未命中原样放行")
    }

    // MARK: - helper

    /// 驱动 proxy 收包（等价 XCPushSocket 调 proxy 的 didReadTalk 回调）。
    private func driveRead(_ talk: FakeTalk, tag: Int = 0) {
        guard let proxy = fakeSocket.delegate as? XCPushDelegateProxy else {
            XCTFail("delegate 应为 proxy")
            return
        }
        proxy.asyncSocket(fakeSocket, didReadTalk: talk, withTag: tag)
    }
}
