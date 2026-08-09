import XCTest

@testable import DodomaCore

/// The M4 allowlist is deliberately one app wide. These rows are what stops a
/// later edit from widening it by accident before M5 exists.
final class AppPolicyTableTests: XCTestCase {
    func testPolicyTable() {
        let cases: [(bundleID: String?, expected: AppPolicy)] = [
            ("com.apple.TextEdit", .normal),
            ("com.apple.Notes", .off),
            ("com.apple.Safari", .off),
            ("com.apple.Terminal", .off),
            ("com.googlecode.iterm2", .off),
            ("com.1password.1password", .off),
            ("com.apple.textedit", .off),  // bundle IDs are matched exactly
            ("", .off),
            (nil, .off),
        ]
        for row in cases {
            XCTAssertEqual(
                AppPolicyTable.policy(forBundleID: row.bundleID), row.expected,
                row.bundleID ?? "nil")
        }
    }

    func testAllowlistIsOnlyTextEdit() {
        XCTAssertEqual(AppPolicyTable.allowlist, ["com.apple.TextEdit"])
    }
}
