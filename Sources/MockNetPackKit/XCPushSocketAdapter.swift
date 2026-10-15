//
//  XCPushSocketAdapter.swift
//  MockNetPackKit
//
//  L5.1：零侵入框架适配器（XCPushSocket）——
//  拦截 XCPushSocket.setDelegate:，插入代理对象，完整转发全部
//  XCAsyncSocketDelegate 回调给原 delegate，业务侧零感知。
//  L5.2：扩展 swizzle `connectToHost:onPort:` / `startHeartbeatWithTimeInterval:` /
//  `stopHeartbeat` / `sendHeartbeatPacket` / `send:tag:`，观察 router / 心跳 /
//  ACK 出站行为；proxy 转发旁路 hooks 接入 XCPushLongConnRecorder 采集。
//  L5.3 mock 拦截在同一转发点预留。
//
//  实现要点：
//  - 不依赖 FDSocketService：`NSClassFromString` 探测类 + ObjC runtime swizzle；
//    框架未加载时 install no-op（与 L6 registry 探测同思路，当前仅做单一类）。
//  - 代理对象 `XCPushDelegateProxy`（ObjC 承载，见 include/XCPushDelegateProxy.h）：
//    显式实现 XCAsyncSocketDelegate 全部 6 回调 + respondsToSelector /
//    methodSignatureForSelector / forwardInvocation 兜底（未来新增回调自动
//    转发或 no-op）。Swift 中 NSInvocation 相关 API 不可用，故代理本体用 ObjC。
//  - proxy 生命周期绑定 socket（associated object RETAIN）；同一 socket 重复
//    `setDelegate:` 幂等（复用同一 proxy，只更新原 delegate 引用）。
//  - 所有 swizzled 实现先采集、再调用原实现（保持业务行为不变）；仅 Debug。
//  - 安装点：MockNetPackKit.start 路径（ConnectionController.start / startUnconfigured），
//    幂等安装，进程内每个目标类只 swizzle 一次。
//

import Foundation
import ObjectiveC
// 代理本体 XCPushDelegateProxy 在独立 C target（SwiftPM，模块 MockNetPackKitObjC）；
// CocoaPods 集成下 .h/.m 编入 pod 自身模块（MockNetPackKit），条件 import 兼容两者。
#if canImport(MockNetPackKitObjC)
import MockNetPackKitObjC
#else
import MockNetPackKit
#endif

/// L5.1/L5.2 XCPushSocket 适配器：swizzle `setDelegate:` 插入 `XCPushDelegateProxy`，
/// 并 swizzle 路由/心跳/发送方法观察出站行为。
enum XCPushSocketAdapter {

    /// 锁保护的状态（Swift 6 并发安全：@unchecked Sendable 容器）。
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var installedClasses: Set<String> = []
        /// 当前已安装目标类（handle 方法经其取原实现；install 后只读）。
        var targetClass: AnyClass?
    }
    private static let state = State()

    /// associated object key：proxy 绑定 socket 生命周期（RETAIN）。
    /// token 为 @unchecked Sendable 单例，地址进程内唯一、稳定。
    private final class AssociationToken: @unchecked Sendable {}
    private static let proxyAssociationToken = AssociationToken()
    private static var proxyAssociationKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(proxyAssociationToken).toOpaque())
    }

    // MARK: - L7.2b 模拟推送注入（活跃 proxy 弱引用表）

    /// 活跃 proxy 弱引用表（L7.2b 注入用）：setDelegate: 首次包裹时登记，
    /// 注入遍历取第一个可用的（原 delegate 非 nil）。同时弱持有 socket——
    /// 注入转发链的 sock 参数必须传真实 socket（nil 会崩业务 delegate 的
    /// 非可选签名；L7.2b 调试中实测 signal 11）。
    private final class WeakProxyBox: @unchecked Sendable {
        weak var proxy: XCPushDelegateProxy?
        weak var socket: AnyObject?
        init(_ proxy: XCPushDelegateProxy, socket: AnyObject) {
            self.proxy = proxy
            self.socket = socket
        }
    }
    private static let proxyState = ProxyState()
    private final class ProxyState: @unchecked Sendable {
        let lock = NSLock()
        var activeProxies: [WeakProxyBox] = []
    }

    /// ACK 包 msgId 解析器（默认为 ObjC helper MNPPacketMsgId；测试注入 fake）。
    /// L7.2b：业务对假包 ACK 经此提取 msgId，判定 ∈ fakeMsgId 集合后丢弃。
    /// 锁保护的可变全局（Swift 6 并发安全）。
    private static let ackResolverState = AckResolverState()
    private final class AckResolverState: @unchecked Sendable {
        let lock = NSLock()
        var resolver: (AnyObject) -> UInt64 = { data in
            MNPPacketMsgId(data as? Data ?? Data())
        }
    }
    static var ackMsgIdResolver: (AnyObject) -> UInt64 {
        get {
            ackResolverState.lock.lock()
            defer { ackResolverState.lock.unlock() }
            return ackResolverState.resolver
        }
        set {
            ackResolverState.lock.lock()
            ackResolverState.resolver = newValue
            ackResolverState.lock.unlock()
        }
    }

    /// 注入假 Packet 到当前活跃长连接（L7.2b 模拟推送）。
    /// 经 proxy.injectFakeTalk:onSocket: 走完整转发链（hooks + originalDelegate），
    /// 不经过 XCPush 收包判重路径（注入点根除，决策 D4）。
    /// 线程对齐（真机崩溃 #3 修复）：proxy 内部先 dispatch_async 回记录的
    /// 真实收包 queue，在该 queue 上走转发链——与真实推送同一执行线程，
    /// 业务 Realm 等线程亲和写不崩。注入期间标记 injecting（recorder 碰撞
    /// 解除豁免该 msgId——假包不能被当成"真实收包碰撞"移除），mark/unmark
    /// 随转发链在目标 queue 上成对执行。
    /// - Returns: 是否入队成功（无活跃连接 → false，指令保留待下次心跳）。
    @discardableResult
    static func injectFakeTalk(packet: AnyObject) -> Bool {
        proxyState.lock.lock()
        defer { proxyState.lock.unlock() }
        // 清理已失效 proxy（originalDelegate 为 nil / 代理已死），取第一个可用注入。
        proxyState.activeProxies.removeAll { $0.proxy?.originalDelegate == nil }
        for box in proxyState.activeProxies {
            if let proxy = box.proxy, let socket = box.socket {
                let msgId = (packet.value(forKey: "msgId") as? NSNumber)?.uint64Value ?? 0
                proxy.injectFakeTalk(packet, onSocket: socket,
                    willInject: { XCPushMockInterceptor.shared.markInjecting(msgId: msgId) },
                    didInject: { XCPushMockInterceptor.shared.unmarkInjecting(msgId: msgId) })
                return true
            }
        }
        SDKLog.error("push mock inject skipped: no active push socket", category: "mock")
        return false
    }

    /// 当前活跃 push 连接数（测试/健康检查）。
    static var activePushConnectionCount: Int {
        proxyState.lock.lock()
        defer { proxyState.lock.unlock() }
        proxyState.activeProxies.removeAll { $0.proxy?.originalDelegate == nil }
        return proxyState.activeProxies.count
    }

    /// 清空活跃 proxy 表（测试用）。
    static func resetActiveProxiesForTesting() {
        proxyState.lock.lock()
        proxyState.activeProxies.removeAll()
        proxyState.lock.unlock()
    }

    private static let setDelegateSelector = NSSelectorFromString("setDelegate:")
    private static let originalSetDelegateSelector = NSSelectorFromString("mnp_original_setDelegate:")

    // MARK: - 安装

    /// 安装适配器（幂等）：探测类存在后 swizzle `setDelegate:` 与出站观察方法。
    /// - Parameter className: 目标类名，默认 "XCPushSocket"；测试注入 fake 类。
    static func installIfNeeded(className: String = "XCPushSocket") {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.installedClasses.contains(className) else { return }
        guard let cls = NSClassFromString(className) else { return }   // 框架未加载：no-op，可重试
        state.targetClass = cls

        // 1) setDelegate: → 代理包裹
        if let origMethod = class_getInstanceMethod(cls, setDelegateSelector) {
            let origIMP = method_getImplementation(origMethod)
            let origTypes = method_getTypeEncoding(origMethod)
            // 原实现挂到 mnp_original_setDelegate:（拦截实现内部经此调用原 setter）
            class_addMethod(cls, originalSetDelegateSelector, origIMP, origTypes)
            // setDelegate: 指向拦截实现（block IMP：避免 Swift 方法 self 类型假设问题）
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { socket, delegate in
                XCPushSocketAdapter.handleSetDelegate(socket: socket, delegate: delegate)
            }
            let newIMP = imp_implementationWithBlock(block as Any)
            class_replaceMethod(cls, setDelegateSelector, newIMP, origTypes)
        }

        // 2) L5.2 出站观察：router / 心跳启停 / 心跳发送 / 发送（ACK tag=12345）
        swizzleConnectToHost(cls)
        swizzleStartHeartbeat(cls)
        swizzleVoidNoArg(cls, "stopHeartbeat") { socket in
            XCPushSocketAdapter.handleStopHeartbeat(socket: socket)
        }
        swizzleVoidNoArg(cls, "sendHeartbeatPacket") { socket in
            XCPushSocketAdapter.handleSendHeartbeatPacket(socket: socket)
        }
        swizzleSendDataTag(cls)

        // L5.6：内置 coder 自动注册（零侵入——业务侧无需注册解码能力）。
        // 探测到 XCPushSocket 类即说明 FDSocketService 框架在，Sync 类大概率存在；
        // coder 内部 NSClassFromString 二次防御，框架缺类时 decode 返 nil 降级。
        LongConnectionCollector.shared.registerCoder(XCPushLongConnRecorder.channelId,
                                                     coder: XCPushChannelCoder())
        // L7.2b：模拟推送注入执行器接线（幂等——install 仅一次，闭包仅此一份）。
        XCPushMockInterceptor.shared.injector = { packet in
            XCPushSocketAdapter.injectFakeTalk(packet: packet)
        }
        SDKLog.info("XCPush adapter installed, built-in coder registered (channel=\(XCPushLongConnRecorder.channelId))",
                       category: "longconn")

        state.installedClasses.insert(className)
    }

    // MARK: - swizzle 实现（各签名独立；先采集后调用原实现）

    /// connectToHost:onPort:（router 观察）。
    private static func swizzleConnectToHost(_ cls: AnyClass) {
        let sel = NSSelectorFromString("connectToHost:onPort:")
        let origSel = NSSelectorFromString("mnp_original_connectToHost:onPort:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        class_addMethod(cls, origSel, method_getImplementation(m), method_getTypeEncoding(m))
        let block: @convention(block) (AnyObject, AnyObject, UInt16) -> Void = { socket, host, port in
            XCPushSocketAdapter.handleConnectToHost(socket: socket, host: host, port: port)
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(block as Any), method_getTypeEncoding(m))
    }

    /// startHeartbeatWithTimeInterval:（心跳间隔观察）。
    private static func swizzleStartHeartbeat(_ cls: AnyClass) {
        let sel = NSSelectorFromString("startHeartbeatWithTimeInterval:")
        let origSel = NSSelectorFromString("mnp_original_startHeartbeatWithTimeInterval:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        class_addMethod(cls, origSel, method_getImplementation(m), method_getTypeEncoding(m))
        let block: @convention(block) (AnyObject, Double) -> Void = { socket, interval in
            XCPushSocketAdapter.handleStartHeartbeat(socket: socket, interval: interval)
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(block as Any), method_getTypeEncoding(m))
    }

    /// send:tag:（ACK 发送观察；tag=12345）。
    private static func swizzleSendDataTag(_ cls: AnyClass) {
        let sel = NSSelectorFromString("send:tag:")
        let origSel = NSSelectorFromString("mnp_original_send:tag:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        class_addMethod(cls, origSel, method_getImplementation(m), method_getTypeEncoding(m))
        let block: @convention(block) (AnyObject, AnyObject, Int) -> Void = { socket, data, tag in
            XCPushSocketAdapter.handleSendDataTag(socket: socket, data: data, tag: tag)
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(block as Any), method_getTypeEncoding(m))
    }

    /// 无参数方法 swizzle（stopHeartbeat / sendHeartbeatPacket）。
    private static func swizzleVoidNoArg(_ cls: AnyClass,
                                         _ selectorName: String,
                                         _ handle: @escaping @convention(block) (AnyObject) -> Void) {
        let sel = NSSelectorFromString(selectorName)
        let origSel = NSSelectorFromString("mnp_original_" + selectorName)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        class_addMethod(cls, origSel, method_getImplementation(m), method_getTypeEncoding(m))
        let imp = imp_implementationWithBlock(handle as Any)
        class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m))
    }

    // MARK: - swizzled 实现入口（block IMP；self = XCPushSocket 实例）

    /// 拦截后的 `setDelegate:` 逻辑。
    private static func handleSetDelegate(socket: AnyObject, delegate: AnyObject?) {
        if let existing = objc_getAssociatedObject(socket, proxyAssociationKey) as? XCPushDelegateProxy {
            // 已包裹：幂等更新原 delegate 引用，复用同一 proxy（不嵌套包裹）。
            existing.originalDelegate = delegate
            _ = socket.perform(originalSetDelegateSelector, with: existing)
            return
        }
        guard let delegate else {
            // 未包裹且 delegate == nil：原样透传。
            _ = socket.perform(originalSetDelegateSelector, with: nil)
            return
        }
        // 首次包裹：创建 proxy，关联到 socket（RETAIN，随 socket 生命周期），
        // 注册采集 hooks（L5.2），把 proxy 交给原 setter。
        let proxy = XCPushDelegateProxy(originalDelegate: delegate)
        attachRecorderHooks(to: proxy)
        objc_setAssociatedObject(socket, proxyAssociationKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // L7.2b：登记活跃 proxy（模拟推送注入目标；weak 持有 socket 供注入转发链）。
        proxyState.lock.lock()
        proxyState.activeProxies.append(WeakProxyBox(proxy, socket: socket))
        proxyState.lock.unlock()
        _ = socket.perform(originalSetDelegateSelector, with: proxy)
    }

    /// 采集 hooks 接线（转发旁路；closeRead 无对应 KK Debug 语义，不采集）。
    /// 注：L7.2b 模拟推送注入时 sock 传 nil——hook 闭包须防御（nil 不能
    /// 强转 AnyObject，否则崩溃；recorder 不依赖 sock 参数）。
    private static func attachRecorderHooks(to proxy: XCPushDelegateProxy) {
        let recorder = XCPushLongConnRecorder.shared
        proxy.didConnectHook = { socket in
            recorder.onDidConnect(socket: socket as AnyObject)
        }
        proxy.disconnectedHook = { socket, error in
            recorder.onDisconnected(socket: socket as AnyObject, error: error as AnyObject?)
        }
        proxy.willForwardReadHook = { sock, talk, tag in
            let s: AnyObject = (sock as AnyObject?) ?? NSNull()
            let t: AnyObject = (talk as AnyObject?) ?? NSNull()
            recorder.onWillForwardRead(sock: s, talk: t, tag: tag)
        }
        proxy.didForwardReadHook = { sock, talk, tag in
            let s: AnyObject = (sock as AnyObject?) ?? NSNull()
            let t: AnyObject = (talk as AnyObject?) ?? NSNull()
            recorder.onDidForwardRead(sock: s, talk: t, tag: tag)
        }
        proxy.timeoutReadHook = { tag in
            recorder.onTimeoutRead(tag: tag)
        }
        proxy.timeoutWriteHook = { tag in
            recorder.onTimeoutWrite(tag: tag)
        }
    }

    /// connectToHost:onPort: 拦截：采集 router + 新连接周期开始，再调原实现。
    private static func handleConnectToHost(socket: AnyObject, host: AnyObject, port: UInt16) {
        XCPushLongConnRecorder.shared.onConnectToHost(host: host as? String ?? "", port: port)
        guard let cls = targetClass() else { return }
        let origSel = NSSelectorFromString("mnp_original_connectToHost:onPort:")
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, UInt16) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(cls, origSel), to: Fn.self)
        fn(socket, origSel, host, port)
    }

    /// startHeartbeatWithTimeInterval: 拦截。
    private static func handleStartHeartbeat(socket: AnyObject, interval: Double) {
        XCPushLongConnRecorder.shared.onHeartbeatStart(interval: interval)
        guard let cls = targetClass() else { return }
        let origSel = NSSelectorFromString("mnp_original_startHeartbeatWithTimeInterval:")
        typealias Fn = @convention(c) (AnyObject, Selector, Double) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(cls, origSel), to: Fn.self)
        fn(socket, origSel, interval)
    }

    /// stopHeartbeat 拦截。
    private static func handleStopHeartbeat(socket: AnyObject) {
        XCPushLongConnRecorder.shared.onHeartbeatStop()
        invokeOriginalVoidNoArg(socket, "mnp_original_stopHeartbeat")
    }

    /// sendHeartbeatPacket 拦截（心跳发送事件，out）。
    private static func handleSendHeartbeatPacket(socket: AnyObject) {
        XCPushLongConnRecorder.shared.onHeartbeatSend()
        invokeOriginalVoidNoArg(socket, "mnp_original_sendHeartbeatPacket")
    }

    /// send:tag: 拦截（tag=12345 = ACK 发送）。
    /// L7.2b：先保留 L5 ackSent 栈内关联采集，再按 fakeMsgId 集合拦截——
    /// 业务对假包的 ACK（msgId ∈ 集合）丢弃不上行 + 旁路上报（决策 D4）；
    /// 真实 push ACK 照常发送，零影响。
    private static func handleSendDataTag(socket: AnyObject, data: AnyObject, tag: Int) {
        XCPushLongConnRecorder.shared.onSend(data: data, tag: tag)
        guard let cls = targetClass() else { return }
        let origSel = NSSelectorFromString("mnp_original_send:tag:")
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(cls, origSel), to: Fn.self)

        guard tag == 12345 else {
            fn(socket, origSel, data, tag)
            return
        }
        // 解析被 ACK 的 msgId → 判定是否为假 push。
        let msgId = ackMsgIdResolver(data)
        if msgId != 0, XCPushMockInterceptor.shared.contains(msgId: msgId) {
            XCPushLongConnRecorder.shared.onMockedAckIntercepted(msgId: msgId)
            SDKLog.info("push mock ACK intercepted (fake msgId=\(msgId)), dropped upstream", category: "mock")
            return  // 丢弃不上行
        }
        fn(socket, origSel, data, tag)
    }

    /// 无参数原实现调用（stopHeartbeat / sendHeartbeatPacket）。
    private static func invokeOriginalVoidNoArg(_ socket: AnyObject, _ originalSelectorName: String) {
        guard let cls = targetClass() else { return }
        let origSel = NSSelectorFromString(originalSelectorName)
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(class_getMethodImplementation(cls, origSel), to: Fn.self)
        fn(socket, origSel)
    }

    /// 读取已安装目标类（锁保护；install 后只读）。
    private static func targetClass() -> AnyClass? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.targetClass
    }
}
