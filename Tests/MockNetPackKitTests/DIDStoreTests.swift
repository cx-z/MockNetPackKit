import XCTest
@testable import MockNetPackKit

final class DIDStoreTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        // 独立 suite，避免污染进程级 UserDefaults.standard。
        suite = UserDefaults(suiteName: "DIDStoreTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "")
        suite = nil
        super.tearDown()
    }

    func testGeneratesNonEmptyDID() {
        let did = DIDStore.did(forApp: "com.test.app", defaults: suite)
        XCTAssertFalse(did.isEmpty)
        XCTAssertEqual(did.count, 36)  // UUID lowercased with hyphens
    }

    func testSameAppReturnsSameDID() {
        let a = DIDStore.did(forApp: "com.test.app", defaults: suite)
        let b = DIDStore.did(forApp: "com.test.app", defaults: suite)
        XCTAssertEqual(a, b, "同一 App 的 did 必须稳定（重启不变）")
    }

    func testDifferentAppsReturnDifferentDIDs() {
        let a = DIDStore.did(forApp: "com.test.app", defaults: suite)
        let b = DIDStore.did(forApp: "com.other.app", defaults: suite)
        XCTAssertNotEqual(a, b, "不同 App 各自独立（服务端以 (app, did) 维度隔离）")
    }

    func testPersistsAcrossStoreReopen() {
        // 模拟"重启"：同一 suite 用新 UserDefaults 实例读取，仍应拿到相同 did。
        let first = DIDStore.did(forApp: "com.test.app", defaults: suite)
        let reopened = DIDStore.did(forApp: "com.test.app", defaults: suite)
        XCTAssertEqual(first, reopened)
    }

    func testResetThenRegenerate() {
        let first = DIDStore.did(forApp: "com.test.app", defaults: suite)
        DIDStore.reset(forApp: "com.test.app", defaults: suite)
        let second = DIDStore.did(forApp: "com.test.app", defaults: suite)
        XCTAssertNotEqual(first, second)
    }
}
