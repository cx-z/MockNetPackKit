import XCTest
@testable import MockNetPackKit

/// 会话级兜底注入的行为契约：
/// 1. 配置在注入生效前创建（protocolClasses 为空）时，创建会话这一刻仍会补上拦截器；
/// 2. SDK 自身转发会话被显式标记后必须跳过注入，避免拦截器递归拦截自己的转发请求。
final class URLSessionConfigurationInjectorTests: XCTestCase {

    /// 确保注入已安装（幂等）；其它用例可能已 stop() 触发过 uninstall。
    override func setUp() {
        super.setUp()
        URLSessionConfigurationInjector.install()
    }

    /// 模拟"注入前生成的长生命周期配置"：构造方法注入被抹掉后，
    /// 创建会话时仍应把 MockNetPackURLProtocol 插回 protocolClasses。
    func testSessionCreationInjectsProtocolIntoStaleConfiguration() {
        var config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let classes = session.configuration.protocolClasses ?? []
        XCTAssertTrue(classes.contains { $0 == MockNetPackURLProtocol.self },
                      "会话创建时应补注入拦截器，实际 protocolClasses=\(classes)")
    }

    /// 标记为 SDK 转发会话的配置不得被注入，否则转发请求会被再次拦截形成递归。
    func testMarkedForwardingConfigurationIsNotInjected() {
        var config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        URLSessionConfigurationInjector.markAsForwardingSession(config)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let classes = session.configuration.protocolClasses ?? []
        XCTAssertFalse(classes.contains { $0 == MockNetPackURLProtocol.self },
                       "转发会话不应带拦截器，实际 protocolClasses=\(classes)")
    }
}
