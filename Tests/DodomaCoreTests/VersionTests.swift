import XCTest
@testable import DodomaCore

final class VersionTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(Dodoma.version, "1.0.0")
    }
}
