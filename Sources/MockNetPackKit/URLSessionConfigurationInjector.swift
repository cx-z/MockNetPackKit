import Foundation
import ObjectiveC

/// URLSessionConfiguration 注入器（M2.4 核心机制）。
///
/// 背景：`URLProtocol.registerClass` 只影响 NSURLConnection 时代的 URL 加载系统；
/// URLSession 的 configuration.protocolClasses 不会自动包含注册类（实测 macOS 亦然）。
/// 业界标准做法（OHHTTPStubs 等）：swizzle `+defaultSessionConfiguration` /
/// `+ephemeralSessionConfiguration` 类方法，在返回的配置中追加拦截器类——
/// 之后所有基于 default/ephemeral 创建的 URLSession（Alamofire / FDNetworkCore /
/// SDWebImage 等）都会携带拦截器，业务代码零改动。
///
/// 与 DoraemonKit 共存：DoraemonKit swizzle 的是实例方法 `protocolClasses`
/// getter（追加式注入自身拦截器）；本注入器 swizzle 的是两个类构造方法，
/// selector 不同，互不干扰。
enum URLSessionConfigurationInjector {

    /// 构造方法原实现（@convention(c) IMP 指针，由 block 捕获）。
    nonisolated(unsafe) private static var origDefaultIMP: IMP?
    nonisolated(unsafe) private static var origEphemeralIMP: IMP?

    typealias ConfigConstructor = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration

    /// 注入：swizzle 两个类构造方法。幂等。
    static func install() {
        guard origDefaultIMP == nil else { return }
        origDefaultIMP = swizzle("defaultSessionConfiguration")
        origEphemeralIMP = swizzle("ephemeralSessionConfiguration")
    }

    /// 还原：恢复原实现。幂等。
    static func uninstall() {
        restore("defaultSessionConfiguration", orig: &origDefaultIMP)
        restore("ephemeralSessionConfiguration", orig: &origEphemeralIMP)
    }

    // MARK: - 私有

    private static func swizzle(_ selectorName: String) -> IMP? {
        let sel = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(URLSessionConfiguration.self, sel) else { return nil }
        let origIMP = method_getImplementation(method)

        // @convention(block)：可捕获上下文；imp_implementationWithBlock 会复制 block，
        // 捕获的 IMP/Selector 均为值拷贝，生命周期安全。
        let block: @convention(block) (AnyObject, Selector) -> URLSessionConfiguration = { target, _ in
            let ctor = unsafeBitCast(origIMP, to: ConfigConstructor.self)
            let config = ctor(target, sel)
            var classes = config.protocolClasses ?? []
            // 必须插到数组最前：URLSession 按顺序询问 canInit，系统 _NSURLHTTPProtocol
            // 在后（且对 http/https 恒返回 true）——追加在末尾的拦截器永远不会被询问。
            // （OHHTTPStubs 同为 insertObject:atIndex:0）
            if !classes.contains(where: { $0 == MockNetPackURLProtocol.self }) {
                classes.insert(MockNetPackURLProtocol.self, at: 0)
            }
            config.protocolClasses = classes
            return config
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
        return origIMP
    }

    private static func restore(_ selectorName: String, orig: inout IMP?) {
        guard let origIMP = orig else { return }
        let sel = NSSelectorFromString(selectorName)
        if let method = class_getClassMethod(URLSessionConfiguration.self, sel) {
            method_setImplementation(method, origIMP)
        }
        orig = nil
    }
}
