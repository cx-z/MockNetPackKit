//
//  XCPushMockInterceptorTests.swift
//  MockNetPackKitTests
//
//  L7.2b 验收：模拟推送引擎（能力线 L7 模拟推送形态，Debug-only）。
//
//  覆盖（对齐执行文档 L7.2b 验收标准）：
//  1. fakeMsgId 集合：register 去重 / contains / mockRuleId / 碰撞解除；
//  2. generateUniqueMsgId：与在册假 msgId 不重复（假 push 间唯一性）；
//  3. makePacket：fake Packet 类构造（type=7/msgId/bizType/bizData）+ 集合注册；
//  4. 注入链路：adapter.injectFakeTalk → proxy 完整转发链 → 原 delegate 收到
//     → 旁路采集假包（mocked=true / mockRuleId / 不进 duplicateIDs）；
//  5. ACK 拦截：业务对假包 ACK（tag=12345）→ 解析 msgId ∈ 集合 → 丢弃不上行
//     + ackBlocked 事件；真实 ACK 照常发送；
//  6. 碰撞解除：真实收包 msgId ∈ 集合 → 移除（后续 ACK 放行、采集不再 mocked）。
//
//  基座复用：FakeXCPushSocket（L5.1）+ FakeTalk（L5.2，internal 跨文件可见）；
//  新增 FakePacket（@objc(FakePacket) 显式注册，供 makePacket 探测）。
//

import Foundation
import XCTest
import ObjectiveC
import Darwin
import MockNetPackKitObjC
@testable import MockNetPackKit

/// 可 KVC 读写的假 Packet（模仿 GPBMessage Packet 字段子集；显式 @objc 名，
/// 供 NSClassFromString 探测）。
@objc(FakePacket) final class FakePacket: NSObject {
    @objc dynamic var type: Int32 = 0
    @objc dynamic var msgId: UInt64 = 0
    @objc dynamic var bizType: Int32 = 0
    @objc dynamic var zipType: Int32 = 0
    @objc dynamic var bizData: Data?
}

/// GPBMessage 行为模拟：字段 storage 在 init 时分配，alloc 后（未 init）写
/// 字段记录 storageViolations——真机 Packet 在此场景直接断言崩溃
/// （'All messages should have storage (from init)'）。用于回归验证
/// makePacket 必须先 init 再 KVC 写字段。
@objc(FakeGPBPacket) final class FakeGPBPacket: NSObject {
    private(set) var initialized = false
    private(set) var storageViolations: [String] = []
    @objc dynamic var type: Int32 = 0 { didSet { guardStorage("type") } }
    @objc dynamic var msgId: UInt64 = 0 { didSet { guardStorage("msgId") } }
    @objc dynamic var bizType: Int32 = 0 { didSet { guardStorage("bizType") } }
    @objc dynamic var zipType: Int32 = 0 { didSet { guardStorage("zipType") } }
    @objc dynamic var bizData: Data? { didSet { guardStorage("bizData") } }
    override init() {
        super.init()
        initialized = true   // 模拟 GPBMessage init 分配 storage
    }
    private func guardStorage(_ key: String) {
        if !initialized { storageViolations.append(key) }
    }
}

/// 原 delegate：记录收包 talk（验证模拟推送注入后业务侧实际收到的数据）。
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

/// 模拟一次真实收包：经 proxy 完整转发链（与真实 XCPush 收包路径一致）。
private func driveRead(_ socket: AnyObject, _ talk: AnyObject, tag: Int = 0) {
    guard let proxy = (socket as? FakeXCPushSocket)?.delegate as? XCPushDelegateProxy else {
        fatalError("delegate 应为 proxy")
    }
    proxy.asyncSocket(socket, didReadTalk: talk, withTag: tag)
}

private func msgSendSendDataTag(_ socket: AnyObject, _ data: AnyObject, _ tag: Int) {
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
    let fn: Fn = dlsymMsgSend(Fn.self)
    fn(socket, NSSelectorFromString("send:tag:"), data, tag)
}

final class XCPushMockInterceptorTests: XCTestCase {

    private var recorder: XCPushLongConnRecorder { .shared }
    private var collected: [LongConnectionRecordInput] = []
    private var fakeSocket: FakeXCPushSocket!
    private var originalDelegate: ReadCaptureDelegate!

    private func makeCommand(id: String = "cmd-1", ruleId: String = "rule-1",
                             bizType: String = "1", payload: String = "{\"say_content\":{\"content\":\"mock\"}}") -> PushRuleCommand {
        PushRuleCommand(id: id, ruleId: ruleId, channelId: "xcpush_tcp",
                        bizType: bizType, payload: payload, payloadBase64: nil)
    }

    override func setUp() {
        super.setUp()
        collected = []
        recorder.recordSink = { [weak self] in self?.collected.append($0) }
        fakeSocket = FakeXCPushSocket()
        originalDelegate = ReadCaptureDelegate()
        XCPushSocketAdapter.resetActiveProxiesForTesting()
        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")
        msgSendSetDelegate(fakeSocket, originalDelegate)
        msgSendConnectToHost(fakeSocket, "router.mock", 9001)
        XCPushMockInterceptor.shared.resetForTesting()
        XCPushMockInterceptor.shared.packetClassName = "FakePacket"
        // 默认 ACK 解析器：测试环境无真 Packet，返回 0 → 不拦截；
        // 拦截用例单独注入 fake resolver。
        XCPushSocketAdapter.ackMsgIdResolver = { _ in 0 }
        // 线程对齐修复：注入派发回「记录的收包 queue」；测试记录主线程，
        // 转发链在主队列异步执行，注入用例用 expectation 等待。
        XCPushDelegateProxy.mnp_recordCurrentReadQueueForTesting()
        collected.removeAll()
    }

    override func tearDown() {
        XCPushSocketAdapter.ackMsgIdResolver = { _ in 0 }
        XCPushMockInterceptor.shared.resetForTesting()
        recorder.recordSink = { MockNetPackKit.recordLongConnection($0) }
        super.tearDown()
    }

    // MARK: - 验收 1：fakeMsgId 集合

    func testFakeMsgIdSetRegisterAndDedup() {
        let interceptor = XCPushMockInterceptor.shared
        XCTAssertTrue(interceptor.register(msgId: 42, ruleId: "r1"))
        XCTAssertFalse(interceptor.register(msgId: 42, ruleId: "r2"), "重复 msgId 注册必须失败")
        XCTAssertTrue(interceptor.contains(msgId: 42))
        XCTAssertEqual(interceptor.mockRuleId(for: 42), "r1")
        XCTAssertEqual(interceptor.fakeMsgIdCount(), 1)
    }

    func testFakeMsgIdSetCollisionResolve() {
        let interceptor = XCPushMockInterceptor.shared
        XCTAssertTrue(interceptor.register(msgId: 1, ruleId: "r1"))
        XCTAssertTrue(interceptor.register(msgId: 2, ruleId: "r2"))
        XCTAssertEqual(interceptor.fakeMsgIdCount(), 2)
        // 碰撞解除后移除。
        XCTAssertTrue(interceptor.resolveCollision(msgId: 1))
        XCTAssertFalse(interceptor.contains(msgId: 1))
        XCTAssertEqual(interceptor.fakeMsgIdCount(), 1)
        XCTAssertFalse(interceptor.resolveCollision(msgId: 1), "重复解除返回 false")
    }

    // MARK: - 验收 2：generateUniqueMsgId（假 push 间唯一性）

    func testGenerateUniqueMsgIdAvoidsRegistered() {
        let interceptor = XCPushMockInterceptor.shared
        XCTAssertTrue(interceptor.register(msgId: 100, ruleId: "r1"))
        var ids: Set<UInt64> = [100]
        var generated: [UInt64] = []
        for _ in 0..<200 {
            let id = interceptor.generateUniqueMsgId()
            XCTAssertFalse(ids.contains(id), "生成值不得与在册/已生成值重复")
            ids.insert(id)
            generated.append(id)
        }
        XCTAssertTrue(generated.allSatisfy { $0 < (UInt64(1) << 63) },
                      "msgId 恒 < 2^63：避免业务 Swift 有符号整数转换 trap（真机崩溃回归）")
    }

    // MARK: - 验收 3：makePacket（构造 + 集合注册）

    func testMakePacketConstructsAndRegisters() {
        let interceptor = XCPushMockInterceptor.shared
        let pkt = interceptor.makePacket(command: makeCommand())
        XCTAssertNotNil(pkt, "FakePacket 类存在时应构造成功")
        let fake = pkt as? FakePacket
        XCTAssertEqual(fake?.type, 7)
        XCTAssertEqual(fake?.bizType, 1)
        XCTAssertEqual(fake?.zipType, 0)
        XCTAssertEqual(fake?.bizData, Data("{\"say_content\":{\"content\":\"mock\"}}".utf8))
        XCTAssertNotEqual(fake?.msgId, 0)
        XCTAssertTrue(interceptor.contains(msgId: fake!.msgId), "构造后必须注册集合")
        XCTAssertEqual(interceptor.mockRuleId(for: fake!.msgId), "rule-1")
        XCTAssertEqual(interceptor.recentInjections(limit: 1).first?.ruleId, "rule-1")
    }

    func testMakePacketFailsWhenClassMissing() {
        let interceptor = XCPushMockInterceptor.shared
        interceptor.packetClassName = "NoSuchPacketClass"
        XCTAssertNil(interceptor.makePacket(command: makeCommand()))
    }

    func testMakePacketPayloadBase64Priority() {
        let interceptor = XCPushMockInterceptor.shared
        let b64 = Data("binary-payload".utf8).base64EncodedString()
        let cmd = PushRuleCommand(id: "c", ruleId: "r", channelId: "xcpush_tcp",
                                  bizType: "2", payload: "text-payload", payloadBase64: b64)
        let fake = interceptor.makePacket(command: cmd) as? FakePacket
        XCTAssertEqual(fake?.bizData, Data("binary-payload".utf8), "payloadBase64 优先")
    }

    func testMakePacketInitsGPBLikeClassBeforeKVCWrite() {
        // 回归（真机崩溃 2026-10-14）：真实 Packet 是 GPBMessage 子类，
        // 字段 storage 在 init 时分配；旧实现 alloc 后直接 KVC 写字段触发
        // 断言 'All messages should have storage (from init)'。此用例用
        // GPB 行为模拟类验证：makePacket 必须先生效 init 再写字段。
        let interceptor = XCPushMockInterceptor.shared
        interceptor.packetClassName = "FakeGPBPacket"
        guard let pkt = interceptor.makePacket(command: makeCommand()) else {
            return XCTFail("FakeGPBPacket 类存在时应构造成功")
        }
        let fake = pkt as? FakeGPBPacket
        XCTAssertNotNil(fake)
        XCTAssertTrue(fake!.initialized, "makePacket 必须先 init（storage 分配）")
        XCTAssertTrue(fake!.storageViolations.isEmpty,
                      "KVC 写字段必须发生在 init 之后：\(fake!.storageViolations)")
        XCTAssertEqual(fake!.type, 7)
        XCTAssertEqual(fake!.bizType, 1)
        XCTAssertEqual(fake!.zipType, 0)
        XCTAssertEqual(fake!.bizData, Data("{\"say_content\":{\"content\":\"mock\"}}".utf8))
        XCTAssertNotEqual(fake!.msgId, 0)
        XCTAssertTrue(interceptor.contains(msgId: fake!.msgId))
    }

    // MARK: - 验收 4：注入链路（proxy 完整转发 + 采集 mocked）

    func testInjectDeliversToOriginalDelegateAndRecordsMocked() {
        let interceptor = XCPushMockInterceptor.shared
        guard let pkt = interceptor.makePacket(command: makeCommand()) else {
            return XCTFail("构造失败")
        }
        // 经 adapter 注入（真机路径：injector = injectFakeTalk；测试同样走 adapter）。
        XCPushMockInterceptor.shared.injector = { packet in
            XCPushSocketAdapter.injectFakeTalk(packet: packet)
        }
        XCTAssertTrue(interceptor.inject(packet: pkt))
        // 注入已派发回记录 queue（测试=主队列），转发链异步执行——等待其跑完。
        let exp = expectation(description: "async inject delivery on recorded queue")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertNotNil(originalDelegate.lastTalk, "原 delegate 必须收到假收包")
        XCTAssertEqual(originalDelegate.lastTag, 0)
        let fake = originalDelegate.lastTalk as? FakePacket
        XCTAssertEqual(fake?.msgId, (pkt as? FakePacket)?.msgId, "业务收到的 msgId 与注入一致")

        let packetRecord = collected.first { $0.eventType == .packet }
        XCTAssertNotNil(packetRecord)
        XCTAssertEqual(packetRecord?.mocked, true, "假包采集必须打 mocked 标记")
        XCTAssertEqual(packetRecord?.mockRuleId, "rule-1")
        XCTAssertEqual(packetRecord?.duplicate, false, "假包不得标 duplicate")
        XCTAssertEqual(packetRecord?.msgId, String((pkt as? FakePacket)!.msgId))
    }

    func testInjectNoActiveSocketReturnsFalse() {
        XCPushSocketAdapter.resetActiveProxiesForTesting()   // 清空活跃连接
        let pkt = FakePacket()
        XCTAssertFalse(XCPushSocketAdapter.injectFakeTalk(packet: pkt),
                       "无活跃连接时注入必须失败（指令保留待下次心跳）")
        XCTAssertNil(originalDelegate.lastTalk)
    }

    // MARK: - 验收 5：ACK 拦截（假包 ACK 丢弃 + ackBlocked 上报；真实 ACK 放行）

    func testFakeAckInterceptedAndDropped() {
        let interceptor = XCPushMockInterceptor.shared
        XCTAssertTrue(interceptor.register(msgId: 555, ruleId: "rule-1"))
        // 注入 ACK 解析器：该 ACK 数据对应的 msgId = 555（假包）。
        XCPushSocketAdapter.ackMsgIdResolver = { _ in 555 }

        let sentBefore = fakeSocket.sentTags.count
        msgSendSendDataTag(fakeSocket, Data([0x01]) as AnyObject, 12345)
        XCTAssertEqual(fakeSocket.sentTags.count, sentBefore, "假包 ACK 必须被丢弃不上行")

        let ackBlocked = collected.first { $0.eventType == .ackBlocked }
        XCTAssertNotNil(ackBlocked, "拦截必须旁路上报 ackBlocked 事件")
        XCTAssertEqual(ackBlocked?.msgId, "555")
    }

    func testRealAckPassesThrough() {
        // 未注册的 msgId（真实包）→ 照常发送。
        XCPushSocketAdapter.ackMsgIdResolver = { _ in 999 }
        let sentBefore = fakeSocket.sentTags.count
        msgSendSendDataTag(fakeSocket, Data([0x01]) as AnyObject, 12345)
        XCTAssertEqual(fakeSocket.sentTags.count, sentBefore + 1, "真实 ACK 必须照常上行")
        XCTAssertNil(collected.first { $0.eventType == .ackBlocked })
    }

    func testNonAckTagNotIntercepted() {
        let interceptor = XCPushMockInterceptor.shared
        XCTAssertTrue(interceptor.register(msgId: 555, ruleId: "rule-1"))
        XCPushSocketAdapter.ackMsgIdResolver = { _ in 555 }
        let sentBefore = fakeSocket.sentTags.count
        msgSendSendDataTag(fakeSocket, Data([0x01]) as AnyObject, 999)   // 非 ACK tag
        XCTAssertEqual(fakeSocket.sentTags.count, sentBefore + 1, "非 ACK tag 不得拦截")
    }

    // MARK: - 验收 6：碰撞解除（真实包 msgId ∈ 集合 → 移除放行）

    func testCollisionResolvedOnRealPacket() {
        let interceptor = XCPushMockInterceptor.shared
        XCTAssertTrue(interceptor.register(msgId: 777, ruleId: "rule-1"))

        // 真实收包（经代理转发链）msgId=777（极端碰撞场景）。
        let real = FakeTalk()
        real.type = 7
        real.bizType = 1
        real.msgId = 777
        real.bizData = Data("real-payload".utf8)
        driveRead(fakeSocket, real)

        // 碰撞解除：集合移除该 msgId。
        XCTAssertFalse(interceptor.contains(msgId: 777), "碰撞解除后该 msgId 不再在册")
        // 采集按真实包展示：不 mocked、不 duplicate（假包集合已移除）。
        let packetRecord = collected.first { $0.eventType == .packet }
        XCTAssertNotNil(packetRecord)
        XCTAssertEqual(packetRecord?.mocked, false, "碰撞解除后采集按真实包展示")
        XCTAssertEqual(packetRecord?.msgId, "777")
        // 原 delegate 收到真实包（放行）。
        XCTAssertEqual((originalDelegate.lastTalk as? FakeTalk)?.msgId, 777)

        // 解除后该 msgId 的 ACK 不再拦截。
        XCPushSocketAdapter.ackMsgIdResolver = { _ in 777 }
        let sentBefore = fakeSocket.sentTags.count
        msgSendSendDataTag(fakeSocket, Data([0x01]) as AnyObject, 12345)
        XCTAssertEqual(fakeSocket.sentTags.count, sentBefore + 1, "碰撞解除后 ACK 照常上行")
    }

    func testCollisionOnlyForMessagePackets() {
        let interceptor = XCPushMockInterceptor.shared
        XCTAssertTrue(interceptor.register(msgId: 888, ruleId: "rule-1"))
        // 非 message 包（heart=5）不带判重语义，不触发解除也不污染。
        let heart = FakeTalk()
        heart.type = 5
        heart.msgId = 888
        driveRead(fakeSocket, heart)
        XCTAssertTrue(interceptor.contains(msgId: 888), "非 message 包不触发碰撞解除")
    }
}
