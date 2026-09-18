import XCTest
@testable import MockNetPackKit

final class MockNetPackKitTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(MockNetPackKit.version.isEmpty)
    }
}
