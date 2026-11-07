import XCTest
@testable import MockNetPackKit

/// 302 回放短期放行缓存：避免 App 跟随重定向时被 SDK 再次拦截造成死循环。
final class RedirectWhitelistTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 每个测试前清空放行缓存（通过加入过期条目再查询触发 lazy cleanup 不彻底，
        // 直接反射清空私有字典不可行，故用 TTL=0 等效清空：所有已有条目都过期）。
        // 由于 redirectWhitelist 是私有静态变量，这里通过多次 add + TTL 等待清理，
        // 或直接用 isWhitelisted 验证行为。
    }

    /// 加入放行缓存后立即查询应命中。
    func testWhitelistHitImmediately() {
        let url = "https://video-test.aimoox.com/pixelmusevd/test-\(UUID().uuidString)"
        MockNetPackURLProtocol.addRedirectWhitelist(urlString: url)
        XCTAssertTrue(MockNetPackURLProtocol.isWhitelisted(urlString: url),
                      "加入放行缓存后应立即命中")
    }

    /// 未加入的 URL 不应命中。
    func testWhitelistMissForUnknownURL() {
        let url = "https://example.com/unknown-\(UUID().uuidString)"
        XCTAssertFalse(MockNetPackURLProtocol.isWhitelisted(urlString: url),
                      "未加入的 URL 不应命中")
    }

    /// 过期条目应自动失效。
    func testWhitelistExpiresAfterTTL() {
        let url = "https://video-test.aimoox.com/pixelmusevd/expire-\(UUID().uuidString)"
        MockNetPackURLProtocol.addRedirectWhitelist(urlString: url)
        XCTAssertTrue(MockNetPackURLProtocol.isWhitelisted(urlString: url))
        // 等待 TTL 过期（redirectWhitelistTTL = 5s，测试等待 5.1s）。
        Thread.sleep(forTimeInterval: MockNetPackURLProtocol.redirectWhitelistTTL + 0.2)
        XCTAssertFalse(MockNetPackURLProtocol.isWhitelisted(urlString: url),
                      "TTL 过期后应自动失效")
    }

    /// 不同 URL 互不影响。
    func testWhitelistIsolationBetweenURLs() {
        let urlA = "https://video-test.aimoox.com/a-\(UUID().uuidString)"
        let urlB = "https://video-test.aimoox.com/b-\(UUID().uuidString)"
        MockNetPackURLProtocol.addRedirectWhitelist(urlString: urlA)
        XCTAssertTrue(MockNetPackURLProtocol.isWhitelisted(urlString: urlA))
        XCTAssertFalse(MockNetPackURLProtocol.isWhitelisted(urlString: urlB))
    }
}
