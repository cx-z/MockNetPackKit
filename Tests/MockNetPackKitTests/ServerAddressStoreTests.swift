import XCTest
@testable import MockNetPackKit

final class ServerAddressStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        // 独立 suite，避免污染进程级 UserDefaults.standard。
        suite = UserDefaults(suiteName: "ServerAddressStoreTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "")
        suite = nil
        super.tearDown()
    }

    func testSaveLoad_RoundTrip() {
        let url = URL(string: "http://mock.local:4290/api/v1")!
        ServerAddressStore.save(url, forApp: "com.test.app", defaults: suite)
        XCTAssertEqual(ServerAddressStore.load(forApp: "com.test.app", defaults: suite), url)
    }

    func testLoad_WhenAbsent_ReturnsNil() {
        XCTAssertNil(ServerAddressStore.load(forApp: "com.test.app", defaults: suite))
    }

    func testDifferentApps_AreIsolated() {
        ServerAddressStore.save(URL(string: "http://a.local/api/v1")!, forApp: "com.test.app", defaults: suite)
        XCTAssertNil(ServerAddressStore.load(forApp: "com.other.app", defaults: suite))
    }

    func testLoad_NonHttpScheme_ReturnsNil() {
        ServerAddressStore.save(URL(string: "ftp://files.local/share")!, forApp: "com.test.app", defaults: suite)
        XCTAssertNil(ServerAddressStore.load(forApp: "com.test.app", defaults: suite))
    }

    func testLoad_EmptyHost_ReturnsNil() {
        ServerAddressStore.save(URL(string: "http://")!, forApp: "com.test.app", defaults: suite)
        XCTAssertNil(ServerAddressStore.load(forApp: "com.test.app", defaults: suite))
    }

    func testClear_Removes() {
        let url = URL(string: "http://mock.local/api/v1")!
        ServerAddressStore.save(url, forApp: "com.test.app", defaults: suite)
        ServerAddressStore.clear(forApp: "com.test.app", defaults: suite)
        XCTAssertNil(ServerAddressStore.load(forApp: "com.test.app", defaults: suite))
    }

    func testReset_Removes() {
        let url = URL(string: "http://mock.local/api/v1")!
        ServerAddressStore.save(url, forApp: "com.test.app", defaults: suite)
        ServerAddressStore.reset(forApp: "com.test.app", defaults: suite)
        XCTAssertNil(ServerAddressStore.load(forApp: "com.test.app", defaults: suite))
    }
}
