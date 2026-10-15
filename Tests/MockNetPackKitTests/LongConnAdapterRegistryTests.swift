//
//  LongConnAdapterRegistryTests.swift
//  MockNetPackKitTests
//
//  L6.1a 验收：适配器 registry（注册/探测/启用调度/幂等/多适配器共存/
// 未命中优雅回退）。
//
//  覆盖：
//  1. 内置适配器已注册（XCPush）；测试环境无 FDSocketService → 探测未命中
//     静默跳过（L6.1b 回退路径）；
//  2. 注册 + 探测命中 → 自动启用（install 被调用且返回 true）；
//  3. 探测未命中（类不存在）→ 不启用、不崩溃；
//  4. installAllIfNeeded 幂等（已启用不重复安装）；
//  5. 同 adapterId 重复注册忽略；
//  6. 多适配器共存（决策 D-L6.3）：命中与未命中并存 → 仅命中者启用；
//  7. resetForTesting 恢复内置注册表。
//
//  基座：记录型 fake 适配器 + 显式 @objc 名的 fake 探测类（Swift @objc 类
//  默认以"模块名.类名"注册 ObjC runtime，NSClassFromString 需按纯类名匹配
//  ——与 XCPushSocketAdapterTests 的 FakeXCPushSocket 同模式）。
//

import Foundation
import XCTest
@testable import MockNetPackKit

/// fake 探测类（显式 @objc 名，NSClassFromString 按纯类名可命中）。
@objc(FakeRegistryProbeA) final class FakeRegistryProbeA: NSObject {}

/// 记录型 fake 适配器 A：探测类存在 → install 成功（命中路径）。
private enum FakeAdapterA: LongConnAdapter {
    static let adapterId = "fake_a"
    static var channelId: String { "fake_a_tcp" }
    static var probeClassNames: [String] { ["FakeRegistryProbeA"] }
    /// 安装调用计数（测试单线程；nonisolated(unsafe) 豁免 Swift 6 全局可变检查）。
    nonisolated(unsafe) static var installCallCount = 0
    /// 记录调用并返回探测结果（命中 → true）。
    static func installIfNeeded() -> Bool {
        installCallCount += 1
        return NSClassFromString("FakeRegistryProbeA") != nil
    }
}

/// 记录型 fake 适配器 B：探测类不存在 → install 失败（未命中/回退路径）。
private enum FakeAdapterB: LongConnAdapter {
    static let adapterId = "fake_b"
    static var channelId: String { "fake_b_tcp" }
    static var probeClassNames: [String] { ["NoSuchProbeClass_XYZ_42"] }
    /// 安装调用计数（测试单线程；nonisolated(unsafe) 豁免 Swift 6 全局可变检查）。
    nonisolated(unsafe) static var installCallCount = 0
    /// 记录调用并返回探测结果（未命中 → false）。
    static func installIfNeeded() -> Bool {
        installCallCount += 1
        return NSClassFromString("NoSuchProbeClass_XYZ_42") != nil
    }
}

final class LongConnAdapterRegistryTests: XCTestCase {

    /// 探测结果日志捕获（L6.1b 日志可观测断言）。
    private var capturedLogs: [String] = []

    override func setUp() {
        super.setUp()
        FakeAdapterA.installCallCount = 0
        FakeAdapterB.installCallCount = 0
        capturedLogs.removeAll()
        LongConnAdapterRegistry.shared.resetForTesting()
        LongConnAdapterRegistry.shared.logSink = { [weak self] msg in
            self?.capturedLogs.append(msg)
        }
    }

    // MARK: - 纯注册制（D-L6.4）：初始为空 + 未注册静默回退

    func testRegistryStartsEmptyAndUnregisteredIsSilentFallback() {
        // 纯注册制（决策 D-L6.4）：注册表初始为空，SDK 不内置任何框架适配器；
        // 接入方显式 register 是唯一接入方式。
        XCTAssertTrue(LongConnAdapterRegistry.shared.registeredAdapterIds.isEmpty,
                      "注册表初始应为空（SDK 不内置适配器）")
        // 未注册任何适配器 → installAllIfNeeded 无 pending，静默跳过：
        // 不崩溃、不报错、不启用（长连接能力未启用可观测）。
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        XCTAssertTrue(LongConnAdapterRegistry.shared.enabledAdapterIds.isEmpty,
                      "无注册适配器时不应启用任何适配器")
        XCTAssertTrue(capturedLogs.isEmpty,
                      "无 pending 适配器时不应输出探测日志（幂等无噪音）")
    }

    // MARK: - 注册 + 探测命中 → 启用

    func testProbeHitEnablesAdapter() {
        LongConnAdapterRegistry.shared.register(FakeAdapterA.self)
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        XCTAssertEqual(FakeAdapterA.installCallCount, 1, "命中适配器应安装一次")
        XCTAssertTrue(LongConnAdapterRegistry.shared.enabledAdapterIds.contains("fake_a"))
    }

    // MARK: - 探测未命中 → 静默回退（L6.1b）

    func testProbeMissIsSilentFallback() {
        LongConnAdapterRegistry.shared.register(FakeAdapterB.self)
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        XCTAssertEqual(FakeAdapterB.installCallCount, 1, "未命中适配器也应被探测一次")
        XCTAssertFalse(LongConnAdapterRegistry.shared.enabledAdapterIds.contains("fake_b"),
                       "类不存在时不应启用")
    }

    // MARK: - 幂等

    func testInstallAllIsIdempotent() {
        LongConnAdapterRegistry.shared.register(FakeAdapterA.self)
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        XCTAssertEqual(FakeAdapterA.installCallCount, 1, "已启用适配器不应重复安装")
    }

    // MARK: - 重复注册忽略

    func testDuplicateRegisterIgnored() {
        LongConnAdapterRegistry.shared.register(FakeAdapterA.self)
        LongConnAdapterRegistry.shared.register(FakeAdapterA.self)
        XCTAssertEqual(LongConnAdapterRegistry.shared.registeredAdapterIds.filter { $0 == "fake_a" }.count, 1,
                       "同 adapterId 重复注册应忽略")
    }

    // MARK: - 多适配器共存（决策 D-L6.3）

    func testMultiAdapterCoexistence() {
        // 命中与未命中并存 → 仅命中者启用，各自独立安装。
        LongConnAdapterRegistry.shared.register(FakeAdapterA.self)   // 命中
        LongConnAdapterRegistry.shared.register(FakeAdapterB.self)   // 未命中
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        XCTAssertTrue(LongConnAdapterRegistry.shared.enabledAdapterIds.contains("fake_a"))
        XCTAssertFalse(LongConnAdapterRegistry.shared.enabledAdapterIds.contains("fake_b"))
        XCTAssertEqual(FakeAdapterA.installCallCount, 1)
        XCTAssertEqual(FakeAdapterB.installCallCount, 1)
    }

    // MARK: - L6.1b 优雅回退日志可观测

    func testNoFrameworkDetectedEmitsFallbackLog() {
        // 注册的适配器均未命中（测试环境无对应框架类）→ 汇总日志
        // （含已探测 adapterId）、不启用（L6.1b 回退可观测）。
        LongConnAdapterRegistry.shared.register(FakeAdapterB.self)
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        XCTAssertFalse(LongConnAdapterRegistry.shared.enabledAdapterIds.contains("fake_b"))
        XCTAssertTrue(capturedLogs.contains { $0.contains("no known framework detected") && $0.contains("fake_b") },
                      "全部未命中应输出优雅回退汇总日志，实际：\(capturedLogs)")
    }

    func testFrameworkDetectedEmitsEnabledLog() {
        LongConnAdapterRegistry.shared.register(FakeAdapterA.self)
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        XCTAssertTrue(capturedLogs.contains { $0.contains("adapters enabled") && $0.contains("fake_a") },
                      "命中适配器应输出启用清单日志，实际：\(capturedLogs)")
    }

    // MARK: - reset 清空注册表（纯注册制 D-L6.4）

    func testResetClearsRegistry() {
        // 纯注册制（决策 D-L6.4）：reset 仅清空注册表，不恢复任何内置适配器。
        LongConnAdapterRegistry.shared.register(FakeAdapterA.self)
        LongConnAdapterRegistry.shared.installAllIfNeeded()
        LongConnAdapterRegistry.shared.resetForTesting()
        XCTAssertTrue(LongConnAdapterRegistry.shared.registeredAdapterIds.isEmpty,
                      "reset 后注册表应为空（SDK 不内置适配器）")
        XCTAssertFalse(LongConnAdapterRegistry.shared.enabledAdapterIds.contains("fake_a"))
    }
}
