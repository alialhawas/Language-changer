import XCTest
@testable import DodomaCore

final class VersionTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(Dodoma.version, "0.1.0")
    }
}
