//
//  LongConnHook.swift
//  MockNetPackKit
//
//  L6.5a（2026-10-16 决策 D-L6.5 方案 A）：通用声明式长连接接入层。
//
//  背景：SDK 将提交 GitHub 公开，主 SDK 不允许集成任何业务方特有/具体框架
//  信息（XCPush 为公司内部框架，SRWebSocket 等开源框架亦不内置）。本文件是
//  公开仓库唯一的「长连接接入面」：业务方以 ≤20 行**声明**（非开发）接入，
//  由 SDK 执行探测、hook、采集与 Mock Push 注入调度。
//
//  设计要点：
//  - 声明即接入：业务方声明 framework/channelId/hook 点/payload 提取闭包/
//    注入闭包；SDK 负责 NSClassFromString 探测 + 方法 hook + 事件记录 +
//    Push Mock 规则调度——不出现任何具体框架类名（探测类名由业务方声明，
//    属接入方配置，非 SDK 内置）。
//  - 签名模板引擎：长连接回调签名各异（无参 / 单对象 / 双对象 /
//    (对象, 对象, UInt16)），引擎按模板 swizzle，先采集再调原实现
//    （业务行为不变）。覆盖主流框架回调形态（didReceiveMessage: /
//    didReadData: / onMessage: / connect / disconnect 等）。
//  - 采集与注入是同一通道能力的两个方向：receive hook 采集真实包；
//    injector 闭包由业务方投递假消息（Mock Push）——框架特有协议逻辑
//    留在业务方自己的工具中（一行调用），公开仓库零框架痕迹。
//  - 安装点：MockNetPackKit.start 路径（ConnectionController.start /
//    startUnconfigured 调 LongConnAdapterRegistry.installAllIfNeeded），
//    幂等可重复调用；未注册任何 hook → 长连接能力静默未启用
//    （L6.1b 优雅回退：不崩溃、不报错，回退日志可观测）。
//  - 多通道共存（决策 D-L6.3）：多次 register 各自探测、各自采集，由
//    channelId 区分。
//

import Foundation
import ObjectiveC

// MARK: - 声明类型（公开面）

/// 被 hook 方法的签名模板（LongConnHook 引擎支持的回调形态）。
///
/// 业务方按自己框架回调的真实签名选择；模板决定 SDK 如何转发参数与
/// 如何调用原实现。覆盖主流长连接框架回调形态：
/// - `.noArg`：无参方法（如 `connect` / `disconnect` / `stopHeartbeat`）
/// - `.singleObject`：单对象参数（如 `onMessage(_ message:)`）
/// - `.twoObjects`：双对象参数（如 `socket(_:didReceiveMessage:)`、
///   `socket(_:didReadData:)`、`connect(to:port:)` 等）
/// - `.twoObjectsUInt16`：（对象, 对象, UInt16）（如 `connectToHost:onPort:`）
public enum LongConnHookTemplate: Sendable {
    case noArg
    case singleObject
    case twoObjects
    case twoObjectsUInt16
}

/// 单个 hook 点声明：方法所在类 + selector + 签名模板。
public struct LongConnHookPoint: Sendable {
    /// 方法所在类名（NSClassFromString 探测；框架未加载则跳过该 hook）。
    public let className: String
    /// 被 hook 的方法 selector。
    public let selector: Selector
    /// 签名模板。
    public let template: LongConnHookTemplate

    public init(className: String, selector: Selector, template: LongConnHookTemplate) {
        self.className = className
        self.selector = selector
        self.template = template
    }
}

/// 业务方声明（≤20 行）：一个长连接通道的完整接入描述。
///
/// - `framework`：能力来源标识（L6.2 采集标注，Web 详情页展示）。
/// - `channelId`：记录维度，多通道共存区分。
/// - `probeClassName`：框架探测类名（nil = 不探测，注册即启用）。
/// - `connect` / `disconnect`：生命周期 hook 点（可选；调用即记录
///   connect/disconnect 事件）。
/// - `receive`：消息接收 hook 点（可选；调用即采集，payload 经
///   `extractPayload` 提取）。
/// - `extractPayload`：回调参数数组 → 可读 payload（可选；不提供时
///   记录不带 payload 的 receive 事件）。框架特有协议解码逻辑由业务方
///   自己的工具提供（此处一行调用）。
/// - `injector`：Mock Push 注入闭包（可选；`PushRuleCommand` → 是否
///   投递成功）。框架特有假消息构造/投递由业务方自己的工具提供
///   （此处一行调用）。
public struct LongConnHookSpec: Sendable {
    public let framework: String
    public let channelId: String
    public let probeClassName: String?
    public let connect: LongConnHookPoint?
    public let disconnect: LongConnHookPoint?
    public let receive: LongConnHookPoint?
    public let extractPayload: (@Sendable ([Any]) -> String?)?
    public let injector: (@Sendable (PushRuleCommand) -> Bool)?

    public init(
        framework: String,
        channelId: String,
        probeClassName: String? = nil,
        connect: LongConnHookPoint? = nil,
        disconnect: LongConnHookPoint? = nil,
        receive: LongConnHookPoint? = nil,
        extractPayload: (@Sendable ([Any]) -> String?)? = nil,
        injector: (@Sendable (PushRuleCommand) -> Bool)? = nil
    ) {
        self.framework = framework
        self.channelId = channelId
        self.probeClassName = probeClassName
        self.connect = connect
        self.disconnect = disconnect
        self.receive = receive
        self.extractPayload = extractPayload
        self.injector = injector
    }
}

// MARK: - 公开入口

/// 通用声明式长连接接入（L6 方案 A；唯一公开接入面）。
public enum LongConnHook {

    /// 注册一个长连接通道声明（幂等：同 channelId 重复注册忽略；
    /// 注册后由 start 路径统一探测/安装）。业务方唯一接入动作。
    /// - Parameter spec: 通道声明（≤20 行）。
    public static func register(_ spec: LongConnHookSpec) {
        LongConnHookEngine.shared.register(spec)
    }
}

// MARK: - 引擎（内部）

/// 声明式 hook 引擎（进程内单例；锁保护，Swift 6 并发安全）。
final class LongConnHookEngine: @unchecked Sendable {

    static let shared = LongConnHookEngine()

    /// 注册条目（安装闭包捕获 spec；规避「存在类型元类型 + 键路径访问
    /// 静态协议需求」的编译器崩溃，见 LongConnAdapterRegistry 文件头注记）。
    private struct Entry: @unchecked Sendable {
        let channelId: String
        let install: () -> Bool
    }

    private let lock = NSLock()
    private var entriesValue: [Entry] = []
    /// 已启用（安装成功）的 channelId（幂等）。
    private var enabledValue: Set<String> = []
    /// 已安装目标类（进程内每个类只 swizzle 一次；swizzle 本身幂等由 install 守卫）。
    private var installedClasses: Set<String> = []

    /// 记录出口（默认上报主 SDK 采集通道；测试注入 fake 收集器）。
    /// L6.2：不带 framework 标识的纯 API 注入记录由 LongConnectionCollector
    /// 统一标注 "unknown-inject"，本引擎记录恒带声明 channelId。
    var recordSink: @Sendable (LongConnectionRecordInput) -> Void = {
        MockNetPackKit.recordLongConnection($0)
    }

    /// 活跃注入器（#if DEBUG：安装成功后挂 PushMockRuleController）。
    /// LongConnHook 注入器经 PushMockInjecting 协议挂载（主 SDK 不依赖
    /// 具体框架实现；协议两步形态 makePacket→inject，LongConnHook 以
    /// command 为包对象占位、业务闭包一步完成构造+投递）。
    private var injectorsValue: [String: PushMockInjecting] = [:]  // channelId → injector

    /// 最近注入记录（injector 的 recentInjections 数据源；测试/日志）。
    private struct InjectionRecord {
        let msgId: UInt64
        let bizType: String
        let ruleId: String
    }
    private var recentInjectionsValue: [InjectionRecord] = []

    private init() {}

    /// 注册声明（幂等：同 channelId 忽略重复）。
    func register(_ spec: LongConnHookSpec) {
        let specBox = SpecBox(spec)  // 捕获不可变快照（Sendable 容器）
        lock.lock()
        guard !entriesValue.contains(where: { $0.channelId == spec.channelId }) else {
            lock.unlock()
            return
        }
        entriesValue.append(Entry(channelId: spec.channelId, install: { [specBox] in
            LongConnHookEngine.shared.install(spec: specBox.spec)
        }))
        lock.unlock()
    }

    /// 探测并安装所有「已注册且未启用」的 hook（安装点 = start 路径）。
    /// 未命中探测类 → 静默跳过（L6.1b 优雅回退，汇总日志可观测）。
    func installAllIfNeeded() {
        let pending: [Entry]
        lock.lock()
        pending = entriesValue.filter { !enabledValue.contains($0.channelId) }
        lock.unlock()
        guard !pending.isEmpty else { return }

        var newlyEnabled: [String] = []
        var skipped: [String] = []
        for entry in pending {
            if entry.install() {
                lock.lock()
                enabledValue.insert(entry.channelId)
                lock.unlock()
                newlyEnabled.append(entry.channelId)
            } else {
                skipped.append(entry.channelId)
            }
        }

        if !newlyEnabled.isEmpty {
            SDKLog.info("longconn hook: channels enabled (\(newlyEnabled.joined(separator: ", ")))",
                        category: "longconn")
        }
        if !skipped.isEmpty {
            SDKLog.info("longconn hook: no known framework detected (channels: \(skipped.joined(separator: ", "))), skipped",
                        category: "longconn")
        }
    }

    /// 已启用 channelId 列表（测试/健康检查）。
    var enabledChannelIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entriesValue.filter { enabledValue.contains($0.channelId) }.map(\.channelId)
    }

    /// 全部已注册 channelId 列表（测试/诊断）。
    var registeredChannelIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entriesValue.map(\.channelId)
    }

    /// 清空注册表（测试用；勿在生产路径调用）。
    func resetForTesting() {
        lock.lock()
        entriesValue.removeAll()
        enabledValue.removeAll()
        installedClasses.removeAll()
        injectorsValue.removeAll()
        recentInjectionsValue.removeAll()
        lock.unlock()
    }

    /// 最近注入记录（LongConnHookInjector.recentInjections 数据源）。
    func recentInjections(limit: Int) -> [(msgId: UInt64, bizType: String, ruleId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentInjectionsValue.suffix(limit)).map {
            (msgId: $0.msgId, bizType: $0.bizType, ruleId: $0.ruleId)
        }
    }

    /// 记录一次注入（injector 闭包成功后调用）。
    func noteInjection(ruleId: String, bizType: String) {
        lock.lock()
        defer { lock.unlock() }
        recentInjectionsValue.append(InjectionRecord(msgId: 0, bizType: bizType, ruleId: ruleId))
        if recentInjectionsValue.count > 100 { recentInjectionsValue.removeFirst(recentInjectionsValue.count - 100) }
    }

    // MARK: - 安装

    /// 安装单个声明（幂等）：探测类 → swizzle hook 点 → 注册通道 →
    /// 挂载注入器。
    /// - Returns: 是否安装成功（探测类不存在 → false，调用方静默跳过）。
    private func install(spec: LongConnHookSpec) -> Bool {
        // 探测：声明的框架类不存在 → 优雅回退（不崩溃、不报错）。
        if let probe = spec.probeClassName {
            guard NSClassFromString(probe) != nil else { return false }
        }

        let hookPoints: [(String, LongConnHookPoint?)] = [
            ("connect", spec.connect),
            ("disconnect", spec.disconnect),
            ("receive", spec.receive),
        ]
        for (kind, point) in hookPoints {
            guard let point else { continue }
            swizzle(point: point, spec: spec, kind: kind)
        }

        // 注册通道（通道元信息记录框架标识；Web 按 channelId 聚合）。
        MockNetPackKit.registerLongConnectionChannel(spec.channelId,
                                                     metadata: ["framework": spec.framework])

        // 注入器挂载（Debug：Mock Push 规则触达时投递；主 SDK 只认协议）。
        if let injector = spec.injector {
            lock.lock()
            installedClasses.insert(spec.channelId)
            lock.unlock()
            #if DEBUG
            let wrapper = LongConnHookInjector(channelId: spec.channelId, inject: injector)
            injectorsValue[spec.channelId] = wrapper
            PushMockRuleController.shared.mockInjector = wrapper
            #endif
        }

        SDKLog.info("longconn hook installed (framework=\(spec.framework), channel=\(spec.channelId))",
                    category: "longconn")
        return true
    }

    // MARK: - 签名模板 swizzle

    /// 按模板 swizzle 一个 hook 点：把原实现挂到 `mnp_original_<sel>`，
    /// 原 selector 指向拦截实现（先采集、再调原实现，业务行为不变）。
    private func swizzle(point: LongConnHookPoint, spec: LongConnHookSpec, kind: String) {
        guard let cls = NSClassFromString(point.className) else { return }
        lock.lock()
        let classKey = "\(point.className)#\(point.selector)"
        guard !installedClasses.contains(classKey) else {
            lock.unlock()
            return
        }
        installedClasses.insert(classKey)
        lock.unlock()

        guard let method = class_getInstanceMethod(cls, point.selector) else {
            SDKLog.info("longconn hook: selector not found (class=\(point.className), sel=\(point.selector)), skipped",
                        category: "longconn")
            return
        }
        let origTypes = method_getTypeEncoding(method)
        let origSelector = NSSelectorFromString("mnp_original_\(point.selector)")
        class_addMethod(cls, origSelector, method_getImplementation(method), origTypes)

        let onCall: (@Sendable ([Any]) -> Void) = { [spec] args in
            self.handleCall(kind: kind, spec: spec, args: args)
        }
        let block = makeBlock(template: point.template, onCall: onCall, origSelector: origSelector)
        class_replaceMethod(cls, point.selector, imp_implementationWithBlock(block as Any), origTypes)
    }

    /// 构造模板 block（签名固定；参数转 [Any] 交给 onCall）。
    private func makeBlock(
        template: LongConnHookTemplate,
        onCall: @escaping (@Sendable ([Any]) -> Void),
        origSelector: Selector
    ) -> Any {
        switch template {
        case .noArg:
            let b: @convention(block) (AnyObject) -> Void = { target in
                onCall([])
                LongConnHookEngine.invokeOriginalNoArg(target, origSelector)
            }
            return b as Any
        case .singleObject:
            let b: @convention(block) (AnyObject, AnyObject?) -> Void = { target, a1 in
                onCall([a1 ?? NSNull()])
                LongConnHookEngine.invokeOriginalSingleObject(target, origSelector, a1)
            }
            return b as Any
        case .twoObjects:
            let b: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { target, a1, a2 in
                onCall([a1 ?? NSNull(), a2 ?? NSNull()])
                LongConnHookEngine.invokeOriginalTwoObjects(target, origSelector, a1, a2)
            }
            return b as Any
        case .twoObjectsUInt16:
            let b: @convention(block) (AnyObject, AnyObject?, UInt16) -> Void = { target, a1, a2 in
                onCall([a1 ?? NSNull(), a2])
                LongConnHookEngine.invokeOriginalTwoObjectsUInt16(target, origSelector, a1, a2)
            }
            return b as Any
        }
    }

    /// 采集/记录统一入口（按 hook 点类型分发）。
    private func handleCall(kind: String, spec: LongConnHookSpec, args: [Any]) {
        switch kind {
        case "connect":
            record(spec: spec, event: .connect, direction: .out, payload: nil)
        case "disconnect":
            record(spec: spec, event: .disconnect, direction: .out, payload: nil)
        case "receive":
            let payload = spec.extractPayload?(args)
            record(spec: spec, event: .packet, direction: .`in`, payload: payload)
        default:
            break
        }
    }

    /// 构造并上报一条长连接记录（channelId 必填；packet 事件 payload
    /// 三选一必填其一——connect/disconnect 可省略 payload）。
    private func record(spec: LongConnHookSpec, event: LongConnectionEventType,
                        direction: LongConnectionDirection, payload: String?) {
        var record = LongConnectionRecordInput(channelId: spec.channelId,
                                               eventType: event,
                                               ts: Date())
        record.direction = direction
        record.payloadText = payload
        recordSink(record)
    }

    // MARK: - 原实现调用（C 函数指针，按模板签名）

    private static func invokeOriginalNoArg(_ target: AnyObject, _ sel: Selector) {
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(type(of: target), sel), to: Fn.self)
        fn(target, sel)
    }

    private static func invokeOriginalSingleObject(_ target: AnyObject, _ sel: Selector, _ a1: AnyObject?) {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(type(of: target), sel), to: Fn.self)
        fn(target, sel, a1)
    }

    private static func invokeOriginalTwoObjects(_ target: AnyObject, _ sel: Selector, _ a1: AnyObject?, _ a2: AnyObject?) {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(type(of: target), sel), to: Fn.self)
        fn(target, sel, a1, a2)
    }

    private static func invokeOriginalTwoObjectsUInt16(_ target: AnyObject, _ sel: Selector, _ a1: AnyObject?, _ a2: UInt16) {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, UInt16) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(type(of: target), sel), to: Fn.self)
        fn(target, sel, a1, a2)
    }
}

/// spec 的 Sendable 快照容器（闭包捕获用）。
private final class SpecBox: @unchecked Sendable {
    let spec: LongConnHookSpec
    init(_ spec: LongConnHookSpec) { self.spec = spec }
}

/// LongConnHook 注入器（适配 PushMockInjecting 协议；业务闭包一步完成
/// 构造+投递——协议两步形态下 makePacket 以 command 占位返回）。
final class LongConnHookInjector: PushMockInjecting {
    private let channelId: String
    private let inject: @Sendable (PushRuleCommand) -> Bool

    init(channelId: String, inject: @escaping @Sendable (PushRuleCommand) -> Bool) {
        self.channelId = channelId
        self.inject = inject
    }

    func makePacket(command: PushRuleCommand) -> AnyObject? {
        // LongConnHook 形态：业务闭包一步完成「构造 + 投递」，包对象
        // 概念由业务方工具内部持有；此处以 command 占位传递。
        command as AnyObject
    }

    func inject(packet: AnyObject) -> Bool {
        guard let command = packet as? PushRuleCommand else { return false }
        let ok = inject(command)
        if ok {
            LongConnHookEngine.shared.noteInjection(ruleId: command.ruleId,
                                                    bizType: command.bizType)
        }
        return ok
    }

    func recentInjections(limit: Int) -> [(msgId: UInt64, bizType: String, ruleId: String)] {
        LongConnHookEngine.shared.recentInjections(limit: limit)
    }
}
