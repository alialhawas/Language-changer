import XCTest

@testable import DodomaCore

final class SegmenterTests: XCTestCase {
    func testMixedBufferSelectsOnlyTheTrailingBadToken() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("check this HSMDIH")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HSMDIH")
        XCTAssertEqual(region.letterCount, 6)
        XCTAssertEqual(region.tokenCount, 1)
        XCTAssertEqual(region.completedTokenCount, 0)
    }

    func testFullGibberishBufferSelectsEverything() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("HC MV; HKH HSMDIH HGDML")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HC MV; HKH HSMDIH HGDML")
        XCTAssertEqual(region.tokenCount, 5)
        XCTAssertEqual(region.completedTokenCount, 4)
        XCTAssertEqual(region.letterCount, 18)
    }

    func testPureEnglishBufferHasNoCandidate() throws {
        let fixture = try DetectorFixture.make()
        for text in [
            "please send me the report",
            "the quick brown fox jumps",
            "let me know if you have any questions",
        ] {
            let keys = try fixture.latinKeys(text)
            XCTAssertNil(fixture.segment(keys), text)
        }
    }

    /// The region has to reach the caret. `deleteCount` counts clusters
    /// immediately behind it, so a region that stopped at the last letter
    /// would delete one letter too many and strand the space:
    /// "hgsghl " − 6 = "h", + "السلام" = "hالسلام".
    func testTrailingSpaceIsPartOfTheRegion() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("check this HSMDIH ")
        let region = try XCTUnwrap(fixture.segment(keys))

        XCTAssertEqual(region.typedText, "HSMDIH ")
        XCTAssertEqual(region.letterCount, 6, "the space is not a letter")
        XCTAssertEqual(region.tokenCount, 1, "the space does not open a token")
        XCTAssertEqual(region.completedTokenCount, 1, "the word was finished with a space")
    }

    func testApplyingTheFixLeavesTheCorrectText() throws {
        let fixture = try DetectorFixture.make()
        let cases: [(typed: String, expected: String)] = [
            ("hgsghl ", "السلام "),
            ("check this lvnsi ", "check this مدرسه "),
            ("check this lvnsi  ", "check this مدرسه  "),
            ("HC MV; HKH HSMDIH HGDML", "اذ ودك انا اسويها اليوم"),
            ("HC MV; HKH HSMDIH HGDML ", "اذ ودك انا اسويها اليوم "),
        ]
        for row in cases {
            let detection = try XCTUnwrap(fixture.detect(row.typed), row.typed)
            let fix = try XCTUnwrap(detection.decision.fix, row.typed)
            XCTAssertEqual(fix.deleteCount, fix.replacedText.count, row.typed)

            var text = row.typed
            text.removeLast(fix.deleteCount)
            text += fix.insertText
            XCTAssertEqual(text, row.expected, "applying the fix to \(row.typed)")
        }
    }

    func testMultipleTrailingSpacesAreAllCarried() throws {
        let fixture = try DetectorFixture.make()
        let region = try XCTUnwrap(fixture.segment(try fixture.latinKeys("hgsghl   ")))
        XCTAssertEqual(region.typedText, "hgsghl   ")
        XCTAssertEqual(region.letterCount, 6)
    }

    func testEmptyAndWhitespaceOnlyBuffersHaveNoCandidate() throws {
        let fixture = try DetectorFixture.make()
        XCTAssertNil(fixture.segment([]))
        XCTAssertNil(fixture.segment(try fixture.latinKeys("   ")))
    }

    func testArabicJunkTypedUnderTheArabicLayoutSelectsEverything() throws {
        let fixture = try DetectorFixture.make()
        // "hello how are you" typed while the Arabic layout was active.
        let typed = "اثممخ اخص شقث غخع"
        let keys = try fixture.arabicKeys(typed)
        let region = try XCTUnwrap(fixture.segment(keys, typedLanguage: .arabic))

        XCTAssertEqual(region.typedText, typed)
        XCTAssertEqual(region.tokenCount, 4)
    }

    func testRealArabicUnderTheArabicLayoutHasNoCandidate() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.arabicKeys("صباح الخير كيف كان يومك")
        XCTAssertNil(fixture.segment(keys, typedLanguage: .arabic))
    }

    /// The walk must stop at the first recognised word, not scan the whole
    /// buffer: everything before a real word was typed on purpose.
    func testWalkStopsAtTheFirstRecognisedWord() throws {
        let fixture = try DetectorFixture.make()
        let keys = try fixture.latinKeys("hkh hsmdih report hkh hsmdih")
        let region = try XCTUnwrap(fixture.segment(keys))
        XCTAssertEqual(region.typedText, "hkh hsmdih")
    }
}
