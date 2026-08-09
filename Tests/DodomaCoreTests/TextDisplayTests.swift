import XCTest

@testable import DodomaCore

/// The "Last fix:" menu line truncates three fields to twenty characters each.
/// Off-by-one arithmetic there is invisible in a menu and easy to get wrong.
final class TextDisplayTests: XCTestCase {
    func testTextAtOrUnderTheLimitIsUntouched() {
        XCTAssertEqual(TextDisplay.middleTruncate("", limit: 20), "")
        XCTAssertEqual(TextDisplay.middleTruncate("HC MV;", limit: 20), "HC MV;")
        // Exactly at the limit: no ellipsis.
        XCTAssertEqual(TextDisplay.middleTruncate("12345678901234567890", limit: 20),
                       "12345678901234567890")
    }

    func testTruncationKeepsBothEndsAndFillsTheLimitExactly() {
        // 20 characters: ten of head, the ellipsis, nine of tail.
        let result = TextDisplay.middleTruncate("HC MV; HKH HSMDIH HGDML", limit: 20)
        XCTAssertEqual(result, "HC MV; HKH…DIH HGDML")
        XCTAssertEqual(result.count, 20)
        XCTAssertTrue(result.hasPrefix("HC MV; HKH"))
        XCTAssertTrue(result.hasSuffix("DIH HGDML"))
    }

    /// When the budget left by the ellipsis is odd, the extra character goes to
    /// the head, where the reader looks first.
    func testHeadTakesTheOddCharacter() {
        XCTAssertEqual(TextDisplay.middleTruncate("abcdefghij", limit: 6), "abc…ij")
        XCTAssertEqual(TextDisplay.middleTruncate("abcdefghij", limit: 7), "abc…hij")
        XCTAssertEqual(TextDisplay.middleTruncate("abcdefghij", limit: 8), "abcd…hij")
    }

    func testTheResultNeverExceedsTheLimit() {
        let text = "اذ ودك انا اسويها اليوم غدا بكرة"
        for limit in 2...25 {
            let result = TextDisplay.middleTruncate(text, limit: limit)
            XCTAssertLessThanOrEqual(result.count, limit, "limit \(limit): \(result)")
        }
    }

    func testALimitTooSmallForAnEllipsisLeavesTheTextAlone() {
        XCTAssertEqual(TextDisplay.middleTruncate("abcdef", limit: 1), "abcdef")
        XCTAssertEqual(TextDisplay.middleTruncate("abcdef", limit: 0), "abcdef")
    }

    func testNewlinesAreFlattened() {
        XCTAssertEqual(TextDisplay.middleTruncate("one\ntwo", limit: 20), "one two")
        XCTAssertFalse(TextDisplay.middleTruncate("a\nb\nc\nd\ne\nf\ng", limit: 5).contains("\n"))
    }

    func testArabicIsTruncatedByCharacterNotByByte() {
        let result = TextDisplay.middleTruncate("اذ ودك انا اسويها اليوم", limit: 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.contains(TextDisplay.ellipsis))
    }
}

/// Which way the suggestion card is laid out, and which corner it hangs from.
final class TextDirectionTests: XCTestCase {
    func testArabicTextIsRightToLeft() {
        XCTAssertTrue(TextDisplay.isRightToLeftDominant("اذ ودك انا اسويها اليوم"))
        XCTAssertTrue(TextDisplay.isRightToLeftDominant("ودك"))
    }

    func testLatinTextIsNot() {
        XCTAssertFalse(TextDisplay.isRightToLeftDominant("hgsghl"))
        XCTAssertFalse(TextDisplay.isRightToLeftDominant("if you want me to do it today"))
    }

    /// Dominance, not presence: a wrong-layout fix carries the separators and
    /// digits the user typed, and those are shared between the two scripts.
    func testAStrayCharacterDoesNotFlipTheCard() {
        XCTAssertTrue(TextDisplay.isRightToLeftDominant("اذ ودك انا اسويها ok"))
        XCTAssertFalse(TextDisplay.isRightToLeftDominant("send this to اسم now please"))
    }

    func testTextWithNoLettersAtAllReadsLeftToRight() {
        XCTAssertFalse(TextDisplay.isRightToLeftDominant(""))
        XCTAssertFalse(TextDisplay.isRightToLeftDominant("123 !? ..."))
        XCTAssertFalse(TextDisplay.isRightToLeftDominant("   "))
    }

    /// Some applications hand back the presentation forms rather than the base
    /// letters, and a card laid out the wrong way for those would be a puzzle
    /// to diagnose.
    func testArabicPresentationFormsCountAsArabic() {
        XCTAssertTrue(TextDisplay.isRightToLeftDominant("\u{FEDF}\u{FEE0}\u{FEE1}"))
    }
}
