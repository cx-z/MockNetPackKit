//
//  LongConnHookTests.swift
//  MockNetPackKitTests
//
//  通用声明式接入层单测。
//
//  验证语义：
//  - 注册即启用；调用 hook 点 → 采集记录 + 原实现仍执行（业务零感知）；
//  - 无 hook 点的声明 → 通道启用但无采集（优雅回退，不崩溃）；
//  - 同 channelId 重复注册幂等；
//  - injector 闭包经 PushMockInjecting 协议挂载并可注入；
//  - 采集记录恒带声明 channelId（adapter 标识）。
//

import XCTest
@testable import MockNetPackKit

final class LongConnHookTests: XCTestCase {

    // MARK: - 模拟框架（@objc 类，供 ObjC runtime swizzle）

    /// 模拟连接类：无参 connect()。
    @objc final class FakeSocket: NSObject {
        nonisolated(unsafe) static var lastConnectCalled = false
        @objc dynamic func connect() {
            FakeSocket.lastConnectCalled = true
        }
    }

    /// 模拟回调类：didReceive(_ message:) 单对象参数。
    @objc final class FakeDelegate: NSObject {
        nonisolated(unsafe) static var lastReceived: String?
        @objc dynamic func didReceive(_ message: NSString) {
            FakeDelegate.lastReceived = message as String
        }
    }

    /// 模拟双对象回调类：socket(_ socket:didReadData data:)。
    @objc final class FakeSocketDelegate: NSObject {
        nonisolated(unsafe) static var lastData: Data?
        @objc dynamic func socket(_ socket: FakeSocket, didReadData data: Data) {
            FakeSocketDelegate.lastData = data
        }
    }

    /// 模拟 (对象, 对象, Int) 回调类：socket(_:didReadTalk:withTag:)。
    @objc final class FakeTagDelegate: NSObject {
        nonisolated(unsafe) static var lastTag: Int?
        @objc dynamic func socket(_ socket: FakeSocket, didReadTalk talk: NSString, withTag tag: Int) {
            FakeTagDelegate.lastTag = tag
        }
    }

    /// 模拟 (对象, UInt16) 回调类（connect(toHost:onPort:) 形态）。
    @objc final class FakePortedSocket: NSObject {
        nonisolated(unsafe) static var lastPort: UInt16?
        @objc dynamic func connect(toHost host: NSString, onPort port: UInt16) {
            FakePortedSocket.lastPort = port
        }
    }

    /// 模拟不支持签名（Float 参数）：引擎应跳过 swizzle，不崩溃。
    @objc final class FakeFloatDelegate: NSObject {
        nonisolated(unsafe) static var lastFloat: Float = 0
        @objc dynamic func socket(_ socket: FakeSocket, didReadFloat value: Float) {
            FakeFloatDelegate.lastFloat = value
        }
    }

    /// 模拟单对象数值回调（NSNumber 装箱）：验证包对象挑选兜底。
    @objc final class FakeNumberDelegate: NSObject {
        nonisolated(unsafe) static var lastNumber: NSNumber?
        @objc dynamic func didReceive(_ value: NSNumber) {
            FakeNumberDelegate.lastNumber = value
        }
    }

    /// 锁保护记录收集器（recordSink 闭包为 @Sendable）。
    private final class RecordCollector: @unchecked Sendable {
        let lock = NSLock()
        var records: [LongConnectionRecordInput] = []
        func append(_ r: LongConnectionRecordInput) {
            lock.lock(); records.append(r); lock.unlock()
        }
        func snapshot() -> [LongConnectionRecordInput] {
            lock.lock(); defer { lock.unlock() }; return records
        }
    }

    override func tearDown() {
        LongConnHookEngine.shared.resetForTesting()
        PushMockRuleController.shared.mockInjector = nil
        FakeSocket.lastConnectCalled = false
        FakeDelegate.lastReceived = nil
        FakeSocketDelegate.lastData = nil
        FakeTagDelegate.lastTag = nil
        FakePortedSocket.lastPort = nil
        FakeFloatDelegate.lastFloat = 0
        FakeNumberDelegate.lastNumber = nil
        super.tearDown()
    }

    private func install(_ spec: LongConnHookSpec) {
        LongConnHook.register(spec)
        LongConnHookEngine.shared.installAllIfNeeded()
    }

    // MARK: - 探测命中：采集 + 原实现调用

    func testProbeHitCollectsAndPreservesOriginalBehavior() {
        let delegateClass = FakeDelegate.self
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            channelId: "fake_tcp",
            connect: LongConnHookPoint(klass: FakeSocket.self,
                                       selector: #selector(FakeSocket.connect)),
            receive: LongConnHookPoint(klass: delegateClass,
                                       selector: #selector(FakeDelegate.didReceive(_:))),
            extractPacket: { raw in
                guard let msg = raw as? NSString else { return nil }
                return LongConnPacketInfo(payloadData: (msg as String).data(using: .utf8) ?? Data())
            }
        ))

        XCTAssertEqual(LongConnHookEngine.shared.enabledChannelIds, ["fake_tcp"],
                       "探测命中应启用 hook")

        // 调用 connect → 记录 connect 事件，原实现仍执行。
        FakeSocket().connect()
        // 调用 receive → 采集 packet + payload 提取正确，原实现仍执行。
        FakeDelegate().didReceive("hello" as NSString)

        XCTAssertTrue(FakeSocket.lastConnectCalled, "原实现必须仍被调用（业务零感知）")
        XCTAssertEqual(FakeDelegate.lastReceived, "hello", "原实现必须仍被调用（业务零感知）")

        let collected = collector.snapshot()
        let events = collected.map(\.eventType)
        XCTAssertTrue(events.contains(.connect), "connect 调用应记录 connect 事件")
        XCTAssertTrue(events.contains(.packet), "receive 调用应记录 packet 事件")

        guard let packet = collected.first(where: { $0.eventType == .packet }) else {
            XCTFail("缺 packet 记录"); return
        }
        XCTAssertEqual(packet.channelId, "fake_tcp")
        XCTAssertEqual(packet.payloadText, "hello", "extractPayload 提取的 payload 应入记录")
        XCTAssertEqual(packet.direction, .`in`)
    }

    // MARK: - 双对象模板（socket(_:didReadData:) 形态）

    func testTwoObjectsTemplate() {
        let delegateClass = FakeSocketDelegate.self
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(klass: delegateClass,
                                       selector: #selector(FakeSocketDelegate.socket(_:didReadData:))),
            extractPacket: { raw in
                // SDK 自动挑包对象（delegate 惯例 (socket, data) → data），
                // 业务闭包直接拿到包、无需操作参数数组。
                guard let data = raw as? Data else { return nil }
                return LongConnPacketInfo(payloadData: data)
            }
        ))

        let delegate = FakeSocketDelegate()
        delegate.socket(FakeSocket(), didReadData: Data("frame1".utf8))
        XCTAssertEqual(FakeSocketDelegate.lastData, Data("frame1".utf8), "原实现仍执行")

        guard let packet = collector.snapshot().first(where: { $0.eventType == .packet }) else {
            XCTFail("缺 packet 记录"); return
        }
        XCTAssertEqual(packet.payloadText, "frame1")
    }

    // MARK: - (对象, 对象, Int) 模板（socket(_:didReadTalk:withTag:) 形态）

    func testTwoObjectsIntTemplate() {
        let delegateClass = FakeTagDelegate.self
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(klass: delegateClass,
                                       selector: #selector(FakeTagDelegate.socket(_:didReadTalk:withTag:))),
            extractPacket: { raw in
                // SDK 自动跳过末尾数值 tag，挑出中间的 talk 对象。
                guard let talk = raw as? NSString else { return nil }
                return LongConnPacketInfo(payloadData: (talk as String).data(using: .utf8) ?? Data())
            }
        ))

        let delegate = FakeTagDelegate()
        delegate.socket(FakeSocket(), didReadTalk: "hello" as NSString, withTag: 7)
        XCTAssertEqual(FakeTagDelegate.lastTag, 7, "原实现仍执行")

        guard let packet = collector.snapshot().first(where: { $0.eventType == .packet }) else {
            XCTFail("缺 packet 记录"); return
        }
        XCTAssertEqual(packet.payloadText, "hello")
    }

    // MARK: - 采集方式如实标注：引擎记录带 channelId 作为 adapter

    func testCollectorLabelsChannelAsAdapter() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(klass: FakeSocketDelegate.self,
                                       selector: #selector(FakeSocketDelegate.socket(_:didReadData:))),
            extractPacket: { _ in LongConnPacketInfo(payloadData: Data("x".utf8)) }
        ))

        FakeSocketDelegate().socket(FakeSocket(), didReadData: Data("x".utf8))
        guard let packet = collector.snapshot().first(where: { $0.eventType == .packet }) else {
            XCTFail("缺 packet 记录"); return
        }
        XCTAssertEqual(packet.adapter, "fake_tcp", "引擎采集应如实标注 channelId 为 adapter")
    }

    // MARK: - extractPacket 返回 nil = 业务方明确告知不采集（心跳/控制包噪音）

    func testReceiveSkippedWhenExtractorReturnsNil() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }
        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(klass: FakeSocketDelegate.self,
                                       selector: #selector(FakeSocketDelegate.socket(_:didReadData:))),
            extractPacket: { _ in nil }
        ))

        FakeSocketDelegate().socket(FakeSocket(), didReadData: Data("x".utf8))
        XCTAssertEqual(collector.snapshot().filter { $0.eventType == .packet }.count, 0,
                       "extractPacket 返回 nil 时不应产生 packet 记录")
    }

    // MARK: - 解码链：customPayloadDecoder 优先，失败 fallthrough 通用链

    func testCustomPayloadDecoderPreferred() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }
        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(klass: FakeSocketDelegate.self,
                                       selector: #selector(FakeSocketDelegate.socket(_:didReadData:))),
            extractPacket: { _ in
                LongConnPacketInfo(payloadData: Data("{}".utf8), summary: "head=1")
            },
            customPayloadDecoder: { _ in "custom-decoded" }
        ))

        FakeSocketDelegate().socket(FakeSocket(), didReadData: Data("{}".utf8))
        let packet = collector.snapshot().first(where: { $0.eventType == .packet })
        XCTAssertEqual(packet?.payloadText, "head=1 payload=custom-decoded",
                       "customPayloadDecoder 非空时应优先于通用链")
    }

    func testCustomReturnsNilFallsThroughToGenericChain() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }
        // payloadData 为未排序 JSON：通用链应 pretty + key 排序。
        let rawJSON = Data("{\"b\":1,\"a\":2}".utf8)
        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(klass: FakeSocketDelegate.self,
                                       selector: #selector(FakeSocketDelegate.socket(_:didReadData:))),
            extractPacket: { _ in LongConnPacketInfo(payloadData: rawJSON) },
            customPayloadDecoder: { _ in nil }
        ))

        FakeSocketDelegate().socket(FakeSocket(), didReadData: rawJSON)
        let packet = collector.snapshot().first(where: { $0.eventType == .packet })
        XCTAssertEqual(packet?.payloadText, "{\n  \"a\" : 2,\n  \"b\" : 1\n}",
                       "custom 返回 nil 时应走 SDK 通用链（JSON pretty + key 排序）")
    }

    func testGzipPayloadAutoInflated() {
        // gzip 压缩的 JSON：通用链应自动嗅探解压后 pretty。
        guard let compressed = Data("{\"k\":1}".utf8).gzipCompressed() else {
            XCTFail("测试前置：gzip 压缩失败"); return
        }
        let text = MNPPayloadPreview.text(of: compressed)
        XCTAssertEqual(text, "{\n  \"k\" : 1\n}", "gzip 数据应自动解压后 JSON pretty")
        // 非 gzip 数据原样返回（嗅探不误伤）。
        XCTAssertEqual(MNPPayloadPreview.text(of: Data("hi".utf8)), "hi")
    }

    // MARK: - 注入态：注入闭包内触发的记录标 mocked + mockRuleId

    func testInjectorMarksMockedRecord() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }
        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(klass: FakeSocketDelegate.self,
                                       selector: #selector(FakeSocketDelegate.socket(_:didReadData:))),
            extractPacket: { _ in LongConnPacketInfo(payloadData: Data("fake".utf8)) }
        ))

        let delegate = FakeSocketDelegate()
        // 注入态内调用 → mocked + mockRuleId。
        LongConnHookEngine.shared.beginInjection("rule-42")
        delegate.socket(FakeSocket(), didReadData: Data("fake".utf8))
        LongConnHookEngine.shared.endInjection()
        // 注入态外调用（真实回调语义）→ 不标 mocked。
        delegate.socket(FakeSocket(), didReadData: Data("real".utf8))

        let packets = collector.snapshot().filter { $0.eventType == .packet }
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].mocked, true)
        XCTAssertEqual(packets[0].mockRuleId, "rule-42")
        XCTAssertEqual(packets[1].mocked, false)
        XCTAssertNil(packets[1].mockRuleId)
    }

    // MARK: - 无 hook 点的声明：通道启用但无采集（优雅回退）

    func testNoHookPointDeclEnablesChannel() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        // hook 点类由业务编译期声明（链接期存在）；不注册任何 hook 点 =
        // 通道启用但无采集（长连接能力静默未启用），不崩溃。
        install(LongConnHookSpec(channelId: "ghost_tcp"))

        XCTAssertEqual(LongConnHookEngine.shared.enabledChannelIds, ["ghost_tcp"],
                       "无 hook 点的声明仍启用通道")
        XCTAssertTrue(collector.snapshot().isEmpty, "无 receive hook 不应产生记录")
        // 不崩溃、不报错：到达此处即通过。
    }

    // MARK: - 重复注册幂等

    func testDuplicateRegistrationIgnored() {
        install(LongConnHookSpec(channelId: "fake_tcp"))
        install(LongConnHookSpec(channelId: "fake_tcp"))

        XCTAssertEqual(LongConnHookEngine.shared.registeredChannelIds, ["fake_tcp"],
                       "同 channelId 重复注册应忽略")
        XCTAssertEqual(LongConnHookEngine.shared.enabledChannelIds, ["fake_tcp"])
    }

    // MARK: - 注入器：经 PushMockInjecting 协议挂载并可注入

    func testInjectorMountedAndInvoked() {
        final class PayloadBox: @unchecked Sendable {
            let lock = NSLock()
            var value: String?
        }
        let box = PayloadBox()
        install(LongConnHookSpec(
            channelId: "fake_tcp",
            injector: { command, ctx in
                box.lock.lock()
                box.value = command.payload
                box.lock.unlock()
                // context 提供假包 msgId 生成（业务塞进自己包字段）。
                _ = ctx.nextFakeMsgId()
                return true
            }
        ))

        guard let injector = PushMockRuleController.shared.mockInjector else {
            XCTFail("injector 应挂载到 PushMockRuleController"); return
        }
        let command = PushRuleCommand(id: "c1", ruleId: "r1", channelId: "fake_tcp",
                                      bizType: "chat", payload: "hello", payloadBase64: nil)
        let ok = injector.inject(command: command)
        XCTAssertTrue(ok, "业务注入闭包返回 true 应视为注入成功")
        box.lock.lock()
        let injected = box.value
        box.lock.unlock()
        XCTAssertEqual(injected, "hello", "业务注入闭包应收到规则 payload")

        let recent = injector.recentInjections(limit: 5)
        XCTAssertEqual(recent.last?.ruleId, "r1", "注入记录应可查询（日志/测试断言）")
        XCTAssertEqual(recent.last?.bizType, "chat")
    }

    // MARK: - (对象, UInt16) 模板（connect(toHost:onPort:) 形态）

    func testTwoObjectsUInt16Template() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            channelId: "fake_tcp",
            connect: LongConnHookPoint(
                klass: FakePortedSocket.self,
                selector: #selector(FakePortedSocket.connect(toHost:onPort:)))
        ))

        FakePortedSocket().connect(toHost: "1.2.3.4", onPort: 8080)
        XCTAssertEqual(FakePortedSocket.lastPort, 8080, "原实现必须仍被调用")

        let events = collector.snapshot().map(\.eventType)
        XCTAssertTrue(events.contains(.connect), "UInt16 模板应正确 swizzle 并记录 connect")
    }

    // MARK: - 不支持签名：记日志跳过，不崩溃、不采集

    func testUnsupportedSignatureSkippedGracefully() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        // Float 参数编码（f）不在推断表内 → swizzle 跳过。
        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(
                klass: FakeFloatDelegate.self,
                selector: #selector(FakeFloatDelegate.socket(_:didReadFloat:)))
        ))

        // 直接调用原方法：未 swizzle，原实现照常执行，不产生记录。
        FakeFloatDelegate().socket(FakeSocket(), didReadFloat: 1.5)
        XCTAssertEqual(FakeFloatDelegate.lastFloat, 1.5, "原实现必须仍被调用")
        XCTAssertTrue(collector.snapshot().isEmpty, "不支持的签名不应产生记录")
        // 不崩溃：到达此处即通过。
    }

    // MARK: - 包对象为数值（NSNumber）时兜底挑选，闭包仍能收到

    func testNumericPacketArgumentFallback() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            channelId: "fake_tcp",
            receive: LongConnHookPoint(
                klass: FakeNumberDelegate.self,
                selector: #selector(FakeNumberDelegate.didReceive(_:))),
            extractPacket: { raw in
                // 兜底：全数值参数时 pickPacketArgument 返回最后一个参数，
                // 业务强转失败返回 nil 不采集；这里验证闭包确实被调用到。
                guard let num = raw as? NSNumber else { return nil }
                return LongConnPacketInfo(payloadData: Data("num=\(num.intValue)".utf8))
            }
        ))

        FakeNumberDelegate().didReceive(42)
        XCTAssertEqual(FakeNumberDelegate.lastNumber, 42)
        let packets = collector.snapshot().filter { $0.eventType == .packet }
        XCTAssertEqual(packets.count, 1, "数值包对象应经兜底挑选到达 extractPacket")
    }

    // MARK: - nextFakeMsgId 连续调用唯一性

    func testNextFakeMsgIdUniqueAcrossCalls() {
        let ctx = LongConnHookInjectContext()
        var seen = Set<UInt64>()
        for _ in 0..<100 {
            let id = ctx.nextFakeMsgId()
            XCTAssertFalse(seen.contains(id), "nextFakeMsgId 连续调用不得重复")
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 100)
    }
}
