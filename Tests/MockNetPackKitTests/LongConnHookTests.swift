//
//  LongConnHookTests.swift
//  MockNetPackKitTests
//
//  L6.5a（2026-10-16 决策 D-L6.5 方案 A）：通用声明式接入层单测。
//
//  验证语义：
//  - 探测命中 → 启用；调用 hook 点 → 采集记录 + 原实现仍执行（业务零感知）；
//  - 探测未命中 → 优雅回退（不启用、不崩溃、不报错）；
//  - 同 channelId 重复注册幂等；
//  - injector 闭包经 PushMockInjecting 协议挂载并可注入；
//  - 采集记录恒带声明 channelId（framework 由通道元信息承载，L6.2）。
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
        super.tearDown()
    }

    private func install(_ spec: LongConnHookSpec) {
        LongConnHook.register(spec)
        LongConnHookEngine.shared.installAllIfNeeded()
    }

    // MARK: - 探测命中：采集 + 原实现调用

    func testProbeHitCollectsAndPreservesOriginalBehavior() {
        let socketClass = NSStringFromClass(FakeSocket.self)
        let delegateClass = NSStringFromClass(FakeDelegate.self)
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            framework: "fake_push",
            channelId: "fake_tcp",
            probeClassName: socketClass,
            connect: LongConnHookPoint(className: socketClass,
                                       selector: #selector(FakeSocket.connect),
                                       template: .noArg),
            receive: LongConnHookPoint(className: delegateClass,
                                       selector: #selector(FakeDelegate.didReceive(_:)),
                                       template: .singleObject),
            extractPayload: { args in
                guard let msg = args.first as? NSString else { return nil }
                return msg as String
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
        let socketClass = NSStringFromClass(FakeSocket.self)
        let delegateClass = NSStringFromClass(FakeSocketDelegate.self)
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            framework: "fake_push",
            channelId: "fake_tcp",
            probeClassName: socketClass,
            receive: LongConnHookPoint(className: delegateClass,
                                       selector: #selector(FakeSocketDelegate.socket(_:didReadData:)),
                                       template: .twoObjects),
            extractPayload: { args in
                guard let data = args.dropFirst().first as? Data else { return nil }
                return String(data: data, encoding: .utf8)
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

    // MARK: - 探测未命中：优雅回退

    func testProbeMissGracefulFallback() {
        let collector = RecordCollector()
        LongConnHookEngine.shared.recordSink = { collector.append($0) }

        install(LongConnHookSpec(
            framework: "ghost",
            channelId: "ghost_tcp",
            probeClassName: "NonExistentFrameworkClass"
        ))

        XCTAssertTrue(LongConnHookEngine.shared.enabledChannelIds.isEmpty,
                      "探测未命中不应启用")
        XCTAssertTrue(collector.snapshot().isEmpty, "未命中不应产生记录")
        // 不崩溃、不报错：到达此处即通过。
    }

    // MARK: - 重复注册幂等

    func testDuplicateRegistrationIgnored() {
        let socketClass = NSStringFromClass(FakeSocket.self)
        install(LongConnHookSpec(
            framework: "fake_push", channelId: "fake_tcp",
            probeClassName: socketClass
        ))
        install(LongConnHookSpec(
            framework: "fake_push_dup", channelId: "fake_tcp",
            probeClassName: socketClass
        ))

        XCTAssertEqual(LongConnHookEngine.shared.registeredChannelIds, ["fake_tcp"],
                       "同 channelId 重复注册应忽略")
        XCTAssertEqual(LongConnHookEngine.shared.enabledChannelIds, ["fake_tcp"])
    }

    // MARK: - 注入器：经 PushMockInjecting 协议挂载并可注入

    func testInjectorMountedAndInvoked() {
        let socketClass = NSStringFromClass(FakeSocket.self)
        final class PayloadBox: @unchecked Sendable {
            let lock = NSLock()
            var value: String?
        }
        let box = PayloadBox()
        install(LongConnHookSpec(
            framework: "fake_push",
            channelId: "fake_tcp",
            probeClassName: socketClass,
            injector: { command in
                box.lock.lock()
                box.value = command.payload
                box.lock.unlock()
                return true
            }
        ))

        guard let injector = PushMockRuleController.shared.mockInjector else {
            XCTFail("injector 应挂载到 PushMockRuleController"); return
        }
        let command = PushRuleCommand(id: "c1", ruleId: "r1", channelId: "fake_tcp",
                                      bizType: "chat", payload: "hello", payloadBase64: nil)
        let ok = injector.inject(packet: command as AnyObject)
        XCTAssertTrue(ok, "业务注入闭包返回 true 应视为注入成功")
        box.lock.lock()
        let injected = box.value
        box.lock.unlock()
        XCTAssertEqual(injected, "hello", "业务注入闭包应收到规则 payload")

        let recent = injector.recentInjections(limit: 5)
        XCTAssertEqual(recent.last?.ruleId, "r1", "注入记录应可查询（日志/测试断言）")
        XCTAssertEqual(recent.last?.bizType, "chat")
    }
}
