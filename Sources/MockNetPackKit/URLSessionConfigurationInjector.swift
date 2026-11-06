import Foundation
import ObjectiveC

/// URLSession 注入器（ 核心机制）。
///
/// 背景：`URLProtocol.registerClass` 只影响 NSURLConnection 时代的 URL 加载系统；
/// URLSession 的 configuration.protocolClasses 不会自动包含注册类（实测 macOS 亦然）。
/// 业界标准做法（OHHTTPStubs 等）：swizzle `+defaultSessionConfiguration` /
/// `+ephemeralSessionConfiguration` 类方法，在返回的配置中追加拦截器类——
/// 之后所有基于 default/ephemeral 创建的 URLSession（Alamofire / FDNetworkCore /
/// SDWebImage 等）都会携带拦截器，业务代码零改动。
///
/// 第二层兜底：只改配置构造方法有一个固有缺口——**在注入生效之前就已创建的
/// 长生命周期会话**（例如进程先启动、SDK 中途才 start，第三方 SDK 早先建好的
/// OSS/上传 session）永远不带拦截器。因此再 swizzle
/// `+[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]`，在会话创建这一刻
/// 对传入的配置补一次拦截器；SDK 自身用于转发请求的会话通过
/// `markAsForwardingSession` 显式排除，避免拦截器递归拦截自己的转发。
///
/// 与 DoraemonKit 共存：DoraemonKit swizzle 的是实例方法 `protocolClasses`
/// getter（追加式注入自身拦截器）；本注入器 swizzle 的是类构造方法与会话构造方法，
/// selector 不同，互不干扰。
enum URLSessionConfigurationInjector {

    /// 构造方法原实现（@convention(c) IMP 指针，由 block 捕获）。
    nonisolated(unsafe) private static var origDefaultIMP: IMP?
    nonisolated(unsafe) private static var origEphemeralIMP: IMP?
    /// 会话构造方法的原实现（会话级兜底注入用）。
    nonisolated(unsafe) private static var origSessionIMP: IMP?
    /// 关联对象键：标记"该配置属于 SDK 自身转发会话"。
    nonisolated(unsafe) private static var forwardingSessionKey: UInt8 = 0

    typealias ConfigConstructor = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
    typealias SessionConstructor = @convention(c) (AnyObject, Selector, URLSessionConfiguration,
                                                   AnyObject?, OperationQueue?) -> URLSession

    /// 注入：swizzle 两个 configuration 构造方法与会话构造方法。幂等；
    /// 任一环节此前失败（IMP 为空）时本次会重试，而不是被已成功的环节挡住。
    static func install() {
        if origDefaultIMP == nil { origDefaultIMP = swizzle("defaultSessionConfiguration") }
        if origEphemeralIMP == nil { origEphemeralIMP = swizzle("ephemeralSessionConfiguration") }
        installSessionHook()
    }

    /// 还原：恢复全部原实现。幂等。
    static func uninstall() {
        restore("defaultSessionConfiguration", orig: &origDefaultIMP)
        restore("ephemeralSessionConfiguration", orig: &origEphemeralIMP)
        restoreSessionHook()
    }

    /// 标记配置专用于 SDK 自身转发会话：会话级注入必须跳过，
    /// 否则转发请求会被再次拦截，形成"拦截→转发→再拦截"的递归。
    /// - Parameter config: 即将用于创建转发会话的配置。
    static func markAsForwardingSession(_ config: URLSessionConfiguration) {
        objc_setAssociatedObject(config, &forwardingSessionKey, NSNumber(value: true),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - 私有

    /// 判断配置是否已被标记为 SDK 自身转发会话。
    /// - Parameter config: 待检查的配置。
    /// - Returns: 标记存在且为真时返回 true。
    private static func isForwardingSession(_ config: URLSessionConfiguration) -> Bool {
        (objc_getAssociatedObject(config, &forwardingSessionKey) as? NSNumber)?.boolValue ?? false
    }

    /// 把拦截器插到配置的 `protocolClasses` 首位；已存在或后台会话时不动。
    /// 必须插到最前：URLSession 按顺序询问 canInit，系统 `_NSURLHTTPProtocol`
    /// 在后（且对 http/https 恒返回 true），追加在末尾的拦截器永远不会被询问。
    /// 后台会话不支持自定义 URLProtocol，强行注入会被系统忽略甚至告警，故跳过。
    /// - Parameter config: 待注入的配置（原地修改）。
    private static func injectProtocol(into config: URLSessionConfiguration) {
        if config.identifier != nil { return }
        var classes = config.protocolClasses ?? []
        guard !classes.contains(where: { $0 == MockNetPackURLProtocol.self }) else { return }
        classes.insert(MockNetPackURLProtocol.self, at: 0)
        config.protocolClasses = classes
    }

    /// swizzle 一个 configuration 类构造方法，在返回配置中注入拦截器。
    /// - Parameter selectorName: 类构造方法名。
    /// - Returns: 原 IMP，供还原使用；方法不存在时返回 nil。
    private static func swizzle(_ selectorName: String) -> IMP? {
        let sel = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(URLSessionConfiguration.self, sel) else { return nil }
        let origIMP = method_getImplementation(method)

        // @convention(block)：可捕获上下文；imp_implementationWithBlock 会复制 block，
        // 捕获的 IMP/Selector 均为值拷贝，生命周期安全。
        // 注意：block 参数只对应方法实参（self 之后），不包含 _cmd；
        // 调用原实现时才需要按 IMP 约定补 Selector。
        let block: @convention(block) (AnyObject) -> URLSessionConfiguration = { target in
            let ctor = unsafeBitCast(origIMP, to: ConfigConstructor.self)
            let config = ctor(target, sel)
            injectProtocol(into: config)
            return config
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
        return origIMP
    }

    /// swizzle `+[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]`，
    /// 在会话创建时对传入配置补注入，覆盖"配置早于注入创建"的会话。
    private static func installSessionHook() {
        guard origSessionIMP == nil else { return }
        let sel = NSSelectorFromString("sessionWithConfiguration:delegate:delegateQueue:")
        guard let method = class_getClassMethod(URLSession.self, sel) else { return }
        let origIMP = method_getImplementation(method)

        // block 只接收方法实参（configuration、delegate、queue），self 由 block 首位承接、不含 _cmd；
        // 调用原实现时再按 IMP 约定补 Selector。
        let block: @convention(block) (AnyObject, URLSessionConfiguration, AnyObject?,
                                       OperationQueue?) -> URLSession = { target, config, delegate, queue in
            if !isForwardingSession(config) {
                injectProtocol(into: config)
            }
            let ctor = unsafeBitCast(origIMP, to: SessionConstructor.self)
            return ctor(target, sel, config, delegate, queue)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
        origSessionIMP = origIMP
    }

    /// 还原会话构造方法。
    private static func restoreSessionHook() {
        guard let origIMP = origSessionIMP else { return }
        let sel = NSSelectorFromString("sessionWithConfiguration:delegate:delegateQueue:")
        if let method = class_getClassMethod(URLSession.self, sel) {
            method_setImplementation(method, origIMP)
        }
        origSessionIMP = nil
    }

    /// 还原一个 configuration 类构造方法。
    /// - Parameters:
    ///   - selectorName: 类构造方法名。
    ///   - orig: 对应的原 IMP 存储位置，还原后置空。
    private static func restore(_ selectorName: String, orig: inout IMP?) {
        guard let origIMP = orig else { return }
        let sel = NSSelectorFromString(selectorName)
        if let method = class_getClassMethod(URLSessionConfiguration.self, sel) {
            method_setImplementation(method, origIMP)
        }
        orig = nil
    }
}
