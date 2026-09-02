import XCTest

@testable import DodomaAppKit
@testable import DodomaCore

/// An application that reports no focused element says one of two things, and
/// which one it is decides whether an accepted suggestion may proceed.
final class FocusOracleTests: XCTestCase {
    /// Ghostty answers no focused element and no windows: it draws its own
    /// cells and exposes no accessibility text surface at all. Nothing was
    /// compared, but nothing contradicted either, so a rewrite the user asked
    /// for by pressing the accept key is allowed to go ahead.
    func testAnAppWithNoAccessibilityTreeReadsAsStructurallySilent() {
        let inspection = FocusOracle.withoutFocusedElement(trusted: true)

        XCTAssertEqual(inspection.caretRead, .unreadable)
        XCTAssertEqual(
            CaretVerification.verdict(read: .unreadable, replacedText: "hgsghl", mode: .bestEffort),
            .proceed,
            "an accepted suggestion must apply in an app that exposes no text")
    }

    /// The same nil without the grant means only that Harf is blind. The
    /// application may have text and a caret; nothing may be concluded from
    /// silence that is ours rather than theirs.
    func testWithoutTheGrantTheSameSilenceIsARefusal() {
        XCTAssertEqual(FocusOracle.withoutFocusedElement(trusted: false).caretRead, .unavailable)

        guard case .downgrade = CaretVerification.verdict(
            read: .unavailable, replacedText: "hgsghl", mode: .bestEffort)
        else { return XCTFail("an unreadable caret without the grant must not proceed") }
    }

    /// The loosening applies only to what the user explicitly asked for. A
    /// silent automatic rewrite in an app whose text cannot be read is exactly
    /// the thing the check exists to prevent, and a terminal is the worst place
    /// to get it wrong.
    func testAutomaticRewritesStayBlockedInSuchAnApp() {
        guard case .downgrade = CaretVerification.verdict(
            read: .unreadable, replacedText: "hgsghl", mode: .required)
        else { return XCTFail("the automatic path must still refuse an unreadable caret") }
    }

    /// The secure-field check fails open on `.unknown`, which is what this
    /// path reports. Password protection in these apps rests on secure event
    /// input, which is checked separately and without accessibility.
    func testSecurityIsUnknownRatherThanAsserted() {
        XCTAssertEqual(FocusOracle.withoutFocusedElement(trusted: true).security, .unknown)
    }
}
