//
//  LongConnHook.swift
//  MockNetPackKit
//
//  通用声明式长连接接入层。
//
//  背景：SDK 将提交 GitHub 公开，主 SDK 不允许集成任何具体框架信息
//  （公司内部推送框架、第三方开源框架均不内置）。本文件是公开仓库唯一的
//  「长连接接入面」：业务方以 ≤20 行**声明**（非开发）接入，由 SDK 执行
//  探测、hook、采集与 Mock Push 注入调度。
//
//  设计要点：
//  - 声明即接入：业务方声明 channelId/hook 点/payload 提取闭包/注入闭包；
//    SDK 负责探测 + 方法 hook + 事件记录 + Push Mock 规则调度——不出现任何
//    具体框架类名（探测类对象由业务方声明，属接入方配置，非 SDK 内置）。
//  - 签名模板引擎：长连接回调签名各异（无参 / 单对象 / 双对象 /
//    (对象, 对象, UInt16)），引擎按模板 swizzle，先采集再调原实现
//    （业务行为不变）。覆盖主流框架回调形态（didReceiveMessage: /
//    didReadData: / onMessage: / connect / disconnect 等）。
//  - 采集与注入是同一通道能力的两个方向：receive hook 采集真实包；
//    injector 闭包由业务方投递假消息（Mock Push）——框架特有协议逻辑
//    留在业务方自己的工具中（一行调用），公开仓库零框架痕迹。
//  - 安装点：MockNetPackKit.start 路径（ConnectionController.start /
//    startUnconfigured 调 LongConnHookEngine.installAllIfNeeded），
//    幂等可重复调用；未注册任何声明 → 长连接能力静默未启用
//    （不崩溃、不报错）。
//  - 多通道共存：多次 register 各自启用、各自采集，由
//    channelId 区分。
//

import Foundation
import ObjectiveC

// MARK: - 声明类型（公开面）

/// 单个 hook 点声明：方法所在类对象 + selector。
///
/// 签名模板（参数个数/类型）由 SDK 从方法的 ObjC 类型编码自动推断，
/// 业务方无需手写。不支持的签名在安装时记日志跳过（不崩溃）。
public struct LongConnHookPoint: Sendable {
    /// 方法所在类对象（编译期类型安全；框架未加载时 swizzle 跳过）。
    public let klass: AnyClass
    /// 被 hook 的方法 selector。
    public let selector: Selector

    public init(klass: AnyClass, selector: Selector) {
        self.klass = klass
        self.selector = selector
    }
}

/// receive hook 解出的一个长连接包：原始包体数据 + 可选头部摘要。
///
/// SDK 拿 `payloadData` 走通用解码链（gzip 嗅探 → 业务 customPayloadDecoder
/// → JSON pretty → UTF-8 → 字节数）；`summary`（如 "type=7 msgId=123
/// bizType=1"，框架特有字段拼装属业务）拼在最终 payload 文本头部。
public struct LongConnPacketInfo: Sendable {
    /// 原始包体（SDK 通用解码链的输入）。
    public let payloadData: Data
    /// 头部摘要（框架特有字段，由业务拼装；可空）。
    public let summary: String?

    public init(payloadData: Data, summary: String? = nil) {
        self.payloadData = payloadData
        self.summary = summary
    }
}

/// 业务方声明（≤20 行）：一个长连接通道的完整接入描述。
///
/// - `channelId`：记录维度 + Mock 规则下发路由 + 采集方式标注
///   （adapter 标识即用它，Web 详情页展示）；必填，多通道并存靠它区分。
/// - `connect` / `disconnect`：生命周期 hook 点（可选；调用即记录
///   connect/disconnect 事件）。
/// - `receive`：消息接收 hook 点（可选；调用即采集，包体经
///   `extractPacket` 解出）。
/// - `extractPacket`：SDK 从 receive hook 参数数组中自动挑出"包对象"
///   （delegate 惯例 `(socket, packet, ...)`，取最后一个非数值参数），
///   业务闭包把它解为 `LongConnPacketInfo`（可选；返回 nil = 此包不采集，
///   如心跳/协议控制包）；不提供时 receive 调用不产生任何记录。
///   注意：包对象可能是 NSNull（原方法参数为 nil 时），务必用 `as?`
///   安全强转，不要 `as!`。
/// - `customPayloadDecoder`：框架特有 payload 解码（可选；如嵌套 protobuf
///   剥层）。对一包原始数据返回可读文本；返回 nil = 交 SDK 通用解码链
///   （gzip 嗅探 → JSON pretty → UTF-8 → 字节数，见 MNPPayloadPreview）。
/// - `injector`：Mock Push 注入闭包（可选；`PushRuleCommand` + 注入上下文
///   → 是否投递成功）。框架特有假消息构造/投递由业务方自己的工具提供
///   （此处一行调用）；假包唯一 msgId 由 `context.nextFakeMsgId()` 生成。
public struct LongConnHookSpec: Sendable {
    public let channelId: String
    public let connect: LongConnHookPoint?
    public let disconnect: LongConnHookPoint?
    public let receive: LongConnHookPoint?
    public let extractPacket: (@Sendable (Any) -> LongConnPacketInfo?)?
    public let customPayloadDecoder: (@Sendable (Data) -> String?)?
    public let injector: (@Sendable (PushRuleCommand, LongConnHookInjectContext) -> Bool)?

    public init(
        channelId: String,
        connect: LongConnHookPoint? = nil,
        disconnect: LongConnHookPoint? = nil,
        receive: LongConnHookPoint? = nil,
        extractPacket: (@Sendable (Any) -> LongConnPacketInfo?)? = nil,
        customPayloadDecoder: (@Sendable (Data) -> String?)? = nil,
        injector: (@Sendable (PushRuleCommand, LongConnHookInjectContext) -> Bool)? = nil
    ) {
        self.channelId = channelId
        self.connect = connect
        self.disconnect = disconnect
        self.receive = receive
        self.extractPacket = extractPacket
        self.customPayloadDecoder = customPayloadDecoder
        self.injector = injector
    }
}

/// Mock Push 注入上下文（injector 闭包入参）：提供框架无关的假包工具。
public final class LongConnHookInjectContext: @unchecked Sendable {
    private let lock = NSLock()
    private var seq: UInt64 = 0

    /// 生成假包唯一 msgId（时间戳高 48 位 + 自增序列），避免与真实消息
    /// 重号被业务去重集合拦截。业务方塞进自己包结构的 msgId 字段。
    public func nextFakeMsgId() -> UInt64 {
        lock.lock()
        seq += 1
        let n = seq
        lock.unlock()
        return (UInt64(Date().timeIntervalSince1970 * 1000) << 16) &+ n
    }
}

// MARK: - 公开入口

/// 通用声明式长连接接入（唯一公开接入面）。
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
        let install: () -> Void
    }

    private let lock = NSLock()
    private var entriesValue: [Entry] = []
    /// 已启用（安装成功）的 channelId（幂等）。
    private var enabledValue: Set<String> = []
    /// 已安装目标类（进程内每个类只 swizzle 一次；swizzle 本身幂等由 install 守卫）。
    private var installedClasses: Set<String> = []

    /// 记录出口（默认上报主 SDK 采集通道；测试注入 fake 收集器）。
    /// 不带 framework 标识的纯 API 注入记录由 LongConnectionCollector
    /// 统一标注 "unknown-inject"，本引擎记录恒带声明 channelId。
    var recordSink: @Sendable (LongConnectionRecordInput) -> Void = {
        MockNetPackKit.recordLongConnection($0)
    }

    /// 活跃注入器（#if DEBUG：安装成功后挂 PushMockRuleController）。
    /// LongConnHook 注入器经 PushMockInjecting 协议挂载（主 SDK 不依赖
    /// 具体框架实现；协议为一步注入形态，业务闭包完成构造+投递）。
    private var injectorsValue: [String: PushMockInjecting] = [:]  // channelId → injector

    /// 最近注入记录（injector 的 recentInjections 数据源；测试/日志）。
    private struct InjectionRecord {
        let msgId: UInt64
        let bizType: String
        let ruleId: String
    }
    private var recentInjectionsValue: [InjectionRecord] = []

    /// 注入态线程键：push mock 注入闭包执行期间标记「当前调用为模拟推送」，
    /// hook 采集据此把记录标 mocked/mockRuleId（Web 展示 fake 徽标）。用线程
    /// 本地存储，避免真实 socket 回调线程与注入调用线程互相误标。
    private static let injectionThreadKey = "com.mocknetpack.longconn.injecting"

    private init() {}

    // MARK: - 注入态（push mock 注入期间采集标记）

    /// 进入注入态（线程本地）：后续本线程 hook 采集的 packet 记录标 mocked。
    /// 由 PushMockRuleController 在调用注入器闭包前调用。
    func beginInjection(_ ruleId: String) {
        Thread.current.threadDictionary[Self.injectionThreadKey] = ruleId
    }

    /// 退出注入态（线程本地）；须与 beginInjection 成对调用。
    func endInjection() {
        Thread.current.threadDictionary.removeObject(forKey: Self.injectionThreadKey)
    }

    /// 当前线程注入中的 push mock 规则 ID（非注入调用返回 nil）。
    func currentInjectionRuleId() -> String? {
        Thread.current.threadDictionary[Self.injectionThreadKey] as? String
    }

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

    /// 安装所有「已注册且未启用」的 hook（安装点 = start 路径）。
    /// 类对象由业务编译期声明（链接期存在），安装恒成功；hook 点方法
    /// 不存在/签名不支持时 swizzle 内部记日志跳过，不影响通道启用。
    func installAllIfNeeded() {
        let pending: [Entry]
        lock.lock()
        pending = entriesValue.filter { !enabledValue.contains($0.channelId) }
        lock.unlock()
        guard !pending.isEmpty else { return }

        var newlyEnabled: [String] = []
        for entry in pending {
            entry.install()
            lock.lock()
            enabledValue.insert(entry.channelId)
            lock.unlock()
            newlyEnabled.append(entry.channelId)
        }
        if !newlyEnabled.isEmpty {
            SDKLog.info("longconn hook: channels enabled (\(newlyEnabled.joined(separator: ", ")))",
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

    /// 安装单个声明（幂等）：swizzle hook 点 → 注册通道 → 挂载注入器。
    /// hook 点方法不存在/签名不支持时 swizzle 内部记日志跳过，不影响通道启用。
    private func install(spec: LongConnHookSpec) {
        let hookPoints: [(String, LongConnHookPoint?)] = [
            ("connect", spec.connect),
            ("disconnect", spec.disconnect),
            ("receive", spec.receive),
        ]
        for (kind, point) in hookPoints {
            guard let point else { continue }
            swizzle(point: point, spec: spec, kind: kind)
        }

        // 注册通道（Web 按 channelId 聚合；adapter 标识即 channelId）。
        MockNetPackKit.registerLongConnectionChannel(spec.channelId,
                                                     metadata: [:])

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

        SDKLog.info("longconn hook installed (channel=\(spec.channelId))",
                    category: "longconn")
    }

    // MARK: - 签名模板 swizzle

    /// 从方法 ObjC 类型编码自动推断签名模板（业务方无需手写 template）。
    /// 64 位 runtime 编码形如 "v24@0:8@16"（含栈偏移量数字），先剥离所有
    /// 数字再按参数形态匹配：v=返回值、@=self、:=_cmd，其后为参数编码。
    /// - Returns: 匹配的模板；不支持的签名返回 nil（安装时记日志跳过）。
    private static func inferTemplate(from typeEncoding: String) -> LongConnHookTemplate? {
        let stripped = typeEncoding.filter { !$0.isNumber }
        guard stripped.hasPrefix("v@:") else { return nil }
        let params = stripped.dropFirst(3)
        switch params {
        case "": return .noArg
        case "@": return .singleObject
        case "@@": return .twoObjects
        case "@S", "@s": return .twoObjectsUInt16   // object + (unsigned) short
        case "@@q", "@@i", "@@l": return .twoObjectsInt  // (object, object, int 系)
        default: return nil
        }
    }

    /// swizzle 一个 hook 点：把原实现挂到 `mnp_original_<sel>`，
    /// 原 selector 指向拦截实现（先采集、再调原实现，业务行为不变）。
    /// 签名模板由方法类型编码自动推断（见 inferTemplate）。
    private func swizzle(point: LongConnHookPoint, spec: LongConnHookSpec, kind: String) {
        let cls: AnyClass = point.klass
        lock.lock()
        let classKey = "\(String(describing: cls))#\(point.selector)"
        guard !installedClasses.contains(classKey) else {
            lock.unlock()
            return
        }
        installedClasses.insert(classKey)
        lock.unlock()

        guard let method = class_getInstanceMethod(cls, point.selector) else {
            SDKLog.info("longconn hook: selector not found (class=\(classKey), sel=\(point.selector)), skipped",
                        category: "longconn")
            return
        }
        guard let encoding = method_getTypeEncoding(method),
              let encodingStr = String(validatingUTF8: encoding),
              let template = Self.inferTemplate(from: encodingStr) else {
            SDKLog.info("longconn hook: unsupported signature (class=\(classKey), sel=\(point.selector)), skipped",
                        category: "longconn")
            return
        }
        let origTypes = method_getTypeEncoding(method)
        let origSelector = NSSelectorFromString("mnp_original_\(point.selector)")
        class_addMethod(cls, origSelector, method_getImplementation(method), origTypes)

        let onCall: (@Sendable ([Any]) -> Void) = { [spec] args in
            self.handleCall(kind: kind, spec: spec, args: args)
        }
        let block = makeBlock(template: template, onCall: onCall, origSelector: origSelector)
        class_replaceMethod(cls, point.selector, imp_implementationWithBlock(block as Any), origTypes)
    }

    /// 签名模板（引擎内部按方法类型编码自动推断；公开面不暴露）。
    private enum LongConnHookTemplate: Sendable {
        case noArg
        case singleObject
        case twoObjects
        case twoObjectsUInt16
        case twoObjectsInt
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
        case .twoObjectsInt:
            // (对象, 对象, Int) 三参数方法：block 需声明 self + 全部 3 个方法参数。
            let b: @convention(block) (AnyObject, AnyObject?, AnyObject?, Int) -> Void = { target, a1, a2, a3 in
                onCall([a1 ?? NSNull(), a2 ?? NSNull(), a3])
                LongConnHookEngine.invokeOriginalTwoObjectsInt(target, origSelector, a1, a2, a3)
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
            // SDK 自动挑包对象（delegate 惯例 (socket, packet, ...)：最后
            // 一个非数值参数）；挑不到 = 全数值参数，无包可采。
            // extractPacket 返回 nil = 业务方明确告知此包不采集（如心跳/
            // 协议控制包，客户端用户不可见、属于噪音）；跳过记录。
            guard let packetArg = Self.pickPacketArgument(from: args),
                  let info = spec.extractPacket?(packetArg) else { break }
            record(spec: spec, event: .packet, direction: .`in`,
                   payload: Self.decodePayload(info: info, spec: spec))
        default:
            break
        }
    }

    /// 从 receive hook 参数数组中挑出"包对象"。delegate 回调惯例为
    /// `(socket, packet, ...)`（末尾常带 tag/flag 等数值参数），规则：
    /// 倒序遍历，最后一个非 NSNumber（数值）且非 NSNull（nil 占位）的参数
    /// 即包对象。若全部参数都是数值/占位（罕见，如单对象数值包），
    /// 兜底返回最后一个参数，保证闭包仍能收到包（由业务强转兜底）。
    /// - Parameter args: hook block 打包的方法参数数组（self 之后）。
    /// - Returns: 包对象；数组为空时返回 nil。
    private static func pickPacketArgument(from args: [Any]) -> Any? {
        guard !args.isEmpty else { return nil }
        for arg in args.reversed() {
            if arg is NSNumber || arg is NSNull { continue }
            return arg
        }
        return args.last  // 全数值/占位兜底
    }

    /// 包体解码链（框架无关通用）：gzip 嗅探解压 → 业务 customPayloadDecoder
    /// （框架特有，如嵌套 protobuf 剥层）→ SDK 通用链（JSON pretty / UTF-8
    /// / 字节数）。最终文本 = 业务 summary 头 + " payload=" + 解码结果。
    private static func decodePayload(info: LongConnPacketInfo, spec: LongConnHookSpec) -> String {
        // ① gzip 嗅探解压（与框架 zipType 字段无关）。
        let inflated = MNPPayloadPreview.gzipInflatedIfNeeded(info.payloadData)
        // ② 业务自定义解码器优先（框架特有）；返回 nil/空 → fallthrough。
        if let custom = spec.customPayloadDecoder,
           let body = custom(inflated), !body.isEmpty {
            return join(summary: info.summary, body: body)
        }
        // ③ SDK 通用链：JSON pretty / UTF-8 原文，失败按字节数兜底。
        let body = MNPPayloadPreview.text(of: inflated) ?? "\(inflated.count)B"
        return join(summary: info.summary, body: body)
    }

    /// 拼接头摘要与包体文本（无摘要时只返回包体）。
    private static func join(summary: String?, body: String) -> String {
        guard let s = summary, !s.isEmpty else { return body }
        return s + " payload=" + body
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
        // 采集记录带通道标识（channelId），Web 详情页展示采集来源。
        record.adapter = spec.channelId
        // 注入态：push mock 注入闭包内触发（本线程）的 packet 记录标 mocked
        // + 规则 ID（Web fake 徽标；服务端递增命中统计）。
        if event == .packet, let ruleId = currentInjectionRuleId() {
            record.mocked = true
            record.mockRuleId = ruleId
        }
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

    private static func invokeOriginalTwoObjectsInt(_ target: AnyObject, _ sel: Selector, _ a1: AnyObject?, _ a2: AnyObject?, _ a3: Int) {
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, Int) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(type(of: target), sel), to: Fn.self)
        fn(target, sel, a1, a2, a3)
    }
}

/// spec 的 Sendable 快照容器（闭包捕获用）。
private final class SpecBox: @unchecked Sendable {
    let spec: LongConnHookSpec
    init(_ spec: LongConnHookSpec) { self.spec = spec }
}

/// LongConnHook 注入器（适配 PushMockInjecting 协议；业务闭包一步完成
/// 构造+投递——协议即一步注入形态；注入闭包带 context）。
final class LongConnHookInjector: PushMockInjecting {
    private let channelId: String
    private let inject: @Sendable (PushRuleCommand, LongConnHookInjectContext) -> Bool
    /// 每通道一份注入上下文（msgId 自增序列；锁内安全）。
    private let context = LongConnHookInjectContext()

    init(channelId: String,
         inject: @escaping @Sendable (PushRuleCommand, LongConnHookInjectContext) -> Bool) {
        self.channelId = channelId
        self.inject = inject
    }

    func inject(command: PushRuleCommand) -> Bool {
        let ok = inject(command, context)
        if ok {
            LongConnHookEngine.shared.noteInjection(ruleId: command.ruleId,
                                                    bizType: command.bizType ?? "")
        }
        return ok
    }

    func recentInjections(limit: Int) -> [(msgId: UInt64, bizType: String, ruleId: String)] {
        LongConnHookEngine.shared.recentInjections(limit: limit)
    }
}
