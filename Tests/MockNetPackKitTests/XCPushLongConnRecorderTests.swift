//
//  XCPushLongConnRecorderTests.swift
//  MockNetPackKitTests
//
//  L5.2 验收：XCPushLongConnRecorder 采集（零侵入代理观察 → 事件记录）。
//
//  覆盖（对齐确认清单交付物）：
//  1. 收包字段映射：msgId/bizType（数字字符串不映射）/zipType/payload base64/
//     duplicate/empty 占位/status/receiver 留空；
//  2. zipType=1 gzip 解压（失败回退原始字节）；
//  3. 代理层自维护去重表（同 msgId 重复 → duplicate）；
//  4. ACK 关联：收包转发栈内 send:tag: 12345 → ackSent/lastAckMsgId；栈外忽略；
//  5. 心跳发送（sendHeartbeatPacket swizzle，out 事件）/ 服务器心跳收包（in）；
//  6. router（connectToHost:onPort: swizzle）→ 快照 + 去重表重置；
//  7. 连接生命周期：didConnect/disconnectedWithError/timeoutRead；
//  8. 快照自维护：synack→ready+clientId、memId→accountMid、心跳间隔、
//     状态变化立即上报 snapshot；
//  9. swizzle 真实生效（objc_msgSend 派发 → 新 IMP + 原实现仍被调用）。
//
//  基座与 L5.1 相同（FakeXCPushSocket @objc 显式名 + perform/objc_msgSend
//  模拟 ObjC 消息派发——Swift 直调 Swift 类方法绕过 swizzle，不可用）。
//

import Foundation
import XCTest
import ObjectiveC
import zlib
import MockNetPackKitObjC
@testable import MockNetPackKit

/// 可 KVC 提取字段的收包对象（模仿 GPBMessage Packet 的可读字段子集）。
@objc final class FakeTalk: NSObject {
    @objc dynamic var type: Int32 = 0
    @objc dynamic var msgId: UInt64 = 0
    @objc dynamic var bizType: Int32 = 0
    @objc dynamic var zipType: Int32 = 0
    @objc dynamic var bizData: Data?
    @objc dynamic var clientId: String?
    @objc dynamic var memId: Int64 = 0
}

/// 原 delegate：收包处理栈内可触发 ACK 发送（对齐 KK p_receivedBussnissData defer 路径）。
@objc final class AckInReadDelegate: NSObject {
    var onRead: ((AnyObject, AnyObject, Int) -> Void)?
    @objc func asyncSocket(_ sock: AnyObject, didReadTalk talk: AnyObject, withTag tag: Int) {
        onRead?(sock, talk, tag)
    }
}

/// gzip 压缩（windowBits=31，对齐 KK 解压侧；仅测试造数用）。
private func gzipCompress(_ data: Data) -> Data {
    var stream = z_stream()
    let initStatus = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                                   Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else { return data }
    defer { deflateEnd(&stream) }

    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        stream.next_in = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
        stream.avail_in = uInt(data.count)
        var status: Int32 = Z_OK
        while status == Z_OK {
            stream.next_out = buffer.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress! }
            stream.avail_out = uInt(buffer.count)
            status = deflate(&stream, Z_FINISH)
            out.append(buffer, count: buffer.count - Int(stream.avail_out))
        }
    }
    return out
}

// MARK: - ObjC 消息派发模拟（swizzle 生效路径）
//
// Swift 6 中 objc_msgSend 被标记 unavailable（变参），经 dlsym 取符号后
// unsafeBitCast 到具体签名（@convention(c)）——测试专用，绕过不可用标记。

import Darwin

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

private func msgSendStartHeartbeat(_ socket: AnyObject, _ interval: Double) {
    typealias Fn = @convention(c) (AnyObject, Selector, Double) -> Void
    let fn: Fn = dlsymMsgSend(Fn.self)
    fn(socket, NSSelectorFromString("startHeartbeatWithTimeInterval:"), interval)
}

private func msgSendSendDataTag(_ socket: AnyObject, _ data: AnyObject, _ tag: Int) {
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
    let fn: Fn = dlsymMsgSend(Fn.self)
    fn(socket, NSSelectorFromString("send:tag:"), data, tag)
}

private func msgSendHeartbeatPacket(_ socket: AnyObject) {
    typealias Fn = @convention(c) (AnyObject, Selector) -> Void
    let fn: Fn = dlsymMsgSend(Fn.self)
    fn(socket, NSSelectorFromString("sendHeartbeatPacket"))
}

private func msgSendStopHeartbeat(_ socket: AnyObject) {
    typealias Fn = @convention(c) (AnyObject, Selector) -> Void
    let fn: Fn = dlsymMsgSend(Fn.self)
    fn(socket, NSSelectorFromString("stopHeartbeat"))
}

final class XCPushLongConnRecorderTests: XCTestCase {

    private var recorder: XCPushLongConnRecorder { .shared }
    private var collected: [LongConnectionRecordInput] = []
    private var fakeSocket: FakeXCPushSocket!
    private var originalDelegate: AckInReadDelegate!

    override func setUp() {
        super.setUp()
        collected = []
        recorder.recordSink = { [weak self] in self?.collected.append($0) }
        fakeSocket = FakeXCPushSocket()
        originalDelegate = AckInReadDelegate()
        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")   // 幂等
        msgSendSetDelegate(fakeSocket, originalDelegate)
        // 模拟连接周期开始（swizzle 派发 → recorder 重置去重表 + 快照 starting）
        msgSendConnectToHost(fakeSocket, "router.example", 9001)
        collected.removeAll()
    }

    override func tearDown() {
        recorder.recordSink = { MockNetPackKit.recordLongConnection($0) }
        super.tearDown()
    }

    // MARK: - 收包字段映射

    func testMessagePacketFieldMapping() {
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 1001
        talk.bizType = 1
        talk.zipType = 0
        talk.bizData = Data("hello".utf8)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.channelId, "xcpush_tcp")
        XCTAssertEqual(packet?.msgId, "1001")
        XCTAssertEqual(packet?.bizType, "1", "bizType 保持数字字符串，不内置映射（决策 2026-10-13）")
        XCTAssertEqual(packet?.zipType, "0")
        XCTAssertEqual(packet?.payloadBase64, Data("hello".utf8).base64EncodedString())
        XCTAssertNil(packet?.payloadText)
        XCTAssertNil(packet?.payloadPreview)
        XCTAssertEqual(packet?.status, .handled)
        XCTAssertFalse(packet?.duplicate ?? true)
        XCTAssertFalse(packet?.empty ?? true)
        XCTAssertFalse(packet?.ackSent ?? true)
        XCTAssertNil(packet?.receiver, "零侵入模式 receiver 留空")
        XCTAssertNil(packet?.receiverResult)
        XCTAssertEqual(packet?.direction, .in)
    }

    func testLargeBizTypeStaysNumericString() {
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 2
        talk.bizType = 87654
        talk.bizData = Data("x".utf8)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.bizType, "87654", "业务大枚举同样保持数字字符串")
    }

    // MARK: - gzip 解压

    func testGzipPayloadInflated() {
        let plain = Data("{\"k\":\"中文字段\"}".utf8)
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 3
        talk.zipType = 1
        talk.bizData = gzipCompress(plain)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.payloadBase64, plain.base64EncodedString(), "zipType=1 应解压后上报")
        XCTAssertEqual(packet?.zipType, "1")
    }

    func testGzipFailureFallsBackToRaw() {
        let raw = Data("not-gzip-bytes".utf8)
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 4
        talk.zipType = 1
        talk.bizData = raw
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.payloadBase64, raw.base64EncodedString(), "解压失败回退原始字节")
    }

    // MARK: - 空包 / 重复包

    func testEmptyPacketUsesPlaceholder() {
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 5
        talk.bizData = nil
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.empty, true)
        XCTAssertEqual(packet?.status, .emptyData)
        XCTAssertEqual(packet?.payloadPreview, "(empty)", "对齐 F4 空包占位")
        XCTAssertNil(packet?.payloadBase64)
    }

    func testDuplicatePacketDetected() {
        let first = FakeTalk()
        first.type = 7
        first.msgId = 42
        first.bizData = Data("first".utf8)
        driveRead(first)
        let second = FakeTalk()
        second.type = 7
        second.msgId = 42
        second.bizData = Data("second".utf8)
        driveRead(second)

        let packets = collected.filter { $0.eventType == .packet }
        XCTAssertEqual(packets.count, 2)
        XCTAssertFalse(packets[0].duplicate)
        XCTAssertEqual(packets[0].status, .handled)
        XCTAssertTrue(packets[1].duplicate, "代理层自维护去重表识别重复包")
        XCTAssertEqual(packets[1].status, .duplicate)
    }

    // MARK: - ACK 关联

    func testAckSentInForwardStack() {
        originalDelegate.onRead = { socket, talk, tag in
            msgSendSendDataTag(socket, Data("ack".utf8) as AnyObject, 12345)
        }
        let talk = FakeTalk()
        talk.type = 7
        talk.msgId = 77
        talk.bizData = Data("msg".utf8)
        driveRead(talk)

        let packet = collected.first { $0.eventType == .packet }
        XCTAssertEqual(packet?.ackSent, true, "收包转发栈内 ACK 发送应关联到本条记录")
        // lastAckMsgId 自维护于快照；ACK 本身不触发快照上报（避免每包一条），
        // 随下一次状态变化（如超时）带出。
        guard let proxy = fakeSocket.delegate as? XCPushDelegateProxy else {
            return XCTFail("delegate 应为 proxy")
        }
        proxy.asyncSocket(fakeSocket, timeoutReadWithTag: 0)
        let snapshot = collected.compactMap(\.snapshot).last
        XCTAssertEqual(snapshot?.lastAckMsgId, "77")
    }

    func testAckOutsideStackIgnored() {
        msgSendSendDataTag(fakeSocket, Data("ack".utf8) as AnyObject, 12345)
        XCTAssertTrue(collected.isEmpty, "栈外 ACK（无 pending）不产生记录")
    }

    // MARK: - 心跳

    func testHeartbeatOutOnSendHeartbeatPacket() {
        msgSendHeartbeatPacket(fakeSocket)
        let hb = collected.first { $0.eventType == .heartbeat }
        XCTAssertNotNil(hb)
        XCTAssertEqual(hb?.direction, .out, "心跳发送为 out 事件（不记 payload）")
        XCTAssertNil(hb?.payloadBase64)
        XCTAssertEqual(fakeSocket.heartbeatSentCount, 1, "swizzle 后原实现仍被调用")
    }

    func testHeartbeatInType5DoesNotEmit() {
        let talk = FakeTalk()
        talk.type = 5
        driveRead(talk)
        // 2026-10-14 决策：服务器心跳回包不单独成事件（避免 out+in 成对重复观感）。
        let hb = collected.first { $0.eventType == .heartbeat }
        XCTAssertNil(hb, "服务器心跳包（type=5）不再产生 in 事件")
        let pkt = collected.first { $0.eventType == .packet }
        XCTAssertNil(pkt, "心跳包不得作为业务包入队")
    }

    // MARK: - router / 连接生命周期

    func testConnectToHostSetsRouterAndResets() {
        // setUp 已触发一次（router.example:9001 → starting）；再触发新周期验证更新与重置
        msgSendConnectToHost(fakeSocket, "r2", 4280)
        let snapshot = collected.compactMap(\.snapshot).last
        XCTAssertEqual(snapshot?.routerHost, "r2")
        XCTAssertEqual(snapshot?.routerPort, 4280)
        XCTAssertEqual(snapshot?.state, "starting")
        XCTAssertEqual(fakeSocket.connectHost, "r2", "原实现被调用")
        XCTAssertEqual(fakeSocket.connectPort, 4280)
    }

    func testConnectToHostResetsDedupTable() {
        // 周期 1：msgId=9 收两次 → 第二次 duplicate
        let t1 = FakeTalk(); t1.type = 7; t1.msgId = 9; t1.bizData = Data("a".utf8)
        driveRead(t1)
        driveRead(t1)
        var packets = collected.filter { $0.eventType == .packet }
        XCTAssertTrue(packets.last?.duplicate == true)

        // 新连接周期（connectToHost）→ 去重表重置 → 同 msgId 不再是重复包
        msgSendConnectToHost(fakeSocket, "r3", 4280)
        collected.removeAll()
        driveRead(t1)
        packets = collected.filter { $0.eventType == .packet }
        XCTAssertEqual(packets.count, 1)
        XCTAssertFalse(packets.first?.duplicate ?? true, "connectToHost 重置去重表")
    }

    func testDidConnectLifecycle() {
        guard let proxy = fakeSocket.delegate as? XCPushDelegateProxy else {
            return XCTFail("delegate 应为 proxy")
        }
        proxy.asyncSocketDidConnect(fakeSocket)

        XCTAssertNotNil(collected.first { $0.eventType == .connect })
        let snapshot = collected.compactMap(\.snapshot).last
        XCTAssertEqual(snapshot?.state, "connected")
        XCTAssertEqual(snapshot?.isSocketConnected, true)
    }

    func testDisconnectLifecycle() {
        guard let proxy = fakeSocket.delegate as? XCPushDelegateProxy else {
            return XCTFail("delegate 应为 proxy")
        }
        let error = NSError(domain: "xcpush", code: -1, userInfo: [NSLocalizedDescriptionKey: "连接被重置"])
        proxy.asyncSocket(fakeSocket, disconnectedWithError: error)

        XCTAssertNotNil(collected.first { $0.eventType == .disconnect })
        let snapshot = collected.compactMap(\.snapshot).last
        XCTAssertEqual(snapshot?.state, "disconnected")
        XCTAssertEqual(snapshot?.isSocketConnected, false)
        XCTAssertEqual(snapshot?.lastError, "连接被重置")
    }

    func testTimeoutReadUpdatesSnapshot() {
        guard let proxy = fakeSocket.delegate as? XCPushDelegateProxy else {
            return XCTFail("delegate 应为 proxy")
        }
        proxy.asyncSocket(fakeSocket, timeoutReadWithTag: 0)
        let snapshot = collected.compactMap(\.snapshot).last
        XCTAssertEqual(snapshot?.state, "disconnected")
        XCTAssertEqual(snapshot?.isSocketConnected, false)
        XCTAssertTrue(snapshot?.lastError?.contains("timeout") == true)
    }

    // MARK: - 快照自维护

    func testSynackSetsReadyAndClientId() {
        let talk = FakeTalk()
        talk.type = 2
        talk.clientId = "client-abc"
        talk.memId = 888
        driveRead(talk)

        let snapshot = collected.compactMap(\.snapshot).last
        XCTAssertEqual(snapshot?.state, "ready", "synack 后状态 ready（对齐 KK debugDidReceiveSynAck）")
        XCTAssertEqual(snapshot?.clientId, "client-abc")
        XCTAssertEqual(snapshot?.accountMid, "888", "memId 从 Packet 提取到 accountMid")
    }

    func testHeartbeatIntervalSnapshot() {
        msgSendStartHeartbeat(fakeSocket, 60)
        let snapshot = collected.compactMap(\.snapshot).last
        XCTAssertEqual(snapshot?.heartbeatInterval, 60)
        XCTAssertEqual(fakeSocket.heartbeatInterval, 60, "原实现被调用")
    }

    func testStopHeartbeatForwarded() {
        msgSendStopHeartbeat(fakeSocket)
        XCTAssertTrue(fakeSocket.heartbeatStopped, "stopHeartbeat 原实现被调用")
        XCTAssertTrue(collected.isEmpty, "stopHeartbeat 无状态变化不产生记录")
    }

    func testSnapshotEmittedOnStateChange() {
        // 每次状态变化（connectToHost/didConnect/synack/…）均立即上报 snapshot
        guard let proxy = fakeSocket.delegate as? XCPushDelegateProxy else {
            return XCTFail("delegate 应为 proxy")
        }
        proxy.asyncSocketDidConnect(fakeSocket)
        let snapshotEvents = collected.filter { $0.eventType == .snapshot }
        XCTAssertFalse(snapshotEvents.isEmpty, "状态变化立即上报 snapshot")
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
