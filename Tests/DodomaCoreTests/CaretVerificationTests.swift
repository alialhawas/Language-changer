import XCTest

@testable import DodomaCore

/// The check that stands between a desynchronised buffer and somebody's text.
final class CaretVerificationTests: XCTestCase {
    private func isProceed(_ axText: String?, _ replaced: String) -> Bool {
        CaretVerification.verdict(axText: axText, replacedText: replaced) == .proceed
    }

    private func reason(_ axText: String?, _ replaced: String) -> String? {
        if case .downgrade(let reason) = CaretVerification.verdict(
            axText: axText, replacedText: replaced)
        {
            return reason
        }
        return nil
    }

    func testExactSuffixMatchProceeds() {
        XCTAssertTrue(isProceed("please send hgsghl", "hgsghl"))
        XCTAssertTrue(isProceed("hgsghl", "hgsghl"), "the field holds nothing else")
    }

    func testMismatchDowngrades() {
        XCTAssertNotNil(reason("please send something else", "hgsghl"))
        XCTAssertNotNil(reason("hgsghl and then more", "hgsghl"), "not at the caret")
        XCTAssertEqual(
            reason("please send HGSGHL", "hgsghl"), "caret text does not end with the typed text",
            "the comparison is case sensitive")
    }

    func testMissingAccessibilityTextDowngrades() {
        XCTAssertEqual(reason(nil, "hgsghl"), "no accessibility text at the caret")
    }

    func testEmptyAccessibilityTextDowngrades() {
        XCTAssertEqual(reason("", "hgsghl"), "caret text is shorter than the typed text")
    }

    func testEmptyReplacementDowngrades() {
        XCTAssertEqual(reason("anything", ""), "the fix replaces nothing")
        XCTAssertEqual(reason(nil, ""), "the fix replaces nothing", "checked before the read")
    }

    func testShorterCaretTextDowngrades() {
        XCTAssertEqual(reason("ghl", "hgsghl"), "caret text is shorter than the typed text")
    }

    /// The buffer routinely ends in the separator the user typed after the
    /// word, and `Fix.replacedText` includes it, so this is the common shape.
    func testArabicTextWithATrailingSpace() {
        XCTAssertTrue(isProceed("قال السلام عليكم ", "السلام عليكم "))
        XCTAssertNotNil(
            reason("قال السلام عليكم", "السلام عليكم "), "the trailing space is part of the match")
    }

    /// Swift's `hasSuffix` compares canonically, so a decomposed rendering
    /// would match a composed one — and then the delete count, which is counted
    /// in what the user typed, would be wrong for what is on screen.
    func testComparisonIsNotUnicodeNormalising() {
        let composed = "\u{0623}"  // ARABIC LETTER ALEF WITH HAMZA ABOVE
        let decomposed = "\u{0627}\u{0654}"  // ALEF + HAMZA ABOVE
        XCTAssertTrue(composed.hasSuffix(decomposed), "precondition: Swift would call these equal")
        XCTAssertNotNil(reason(composed, decomposed))
    }

    func testMatchAcrossACombiningBoundaryIsNotSplit() {
        // The caret text ends mid-cluster relative to the replacement, so the
        // UTF-16 suffix cannot line up.
        XCTAssertNotNil(reason("abc\u{0627}", "\u{0627}\u{0654}"))
    }
}
