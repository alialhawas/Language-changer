import XCTest

@testable import DodomaCore

final class LayoutRendererTests: XCTestCase {
    /// Reference capture: this Latin text typed with Caps Lock on is what the
    /// user meant to type in Arabic.
    private let latinPhrase = "HC MV; HKH HSMDIH HGDML"
    private let arabicPhrase = "اذ ودك انا اسويها اليوم"

    private func keys(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> [CapturedKey]
    {
        try XCTUnwrap(KeycodeMap.keys(forLatin: text), file: file, line: line)
    }

    func testArabicRenderingIgnoresCaseModifiers() throws {
        let arabic = try LayoutFixtures.layout(LayoutFixtures.arabicSourceID)
        let keys = try keys(latinPhrase)

        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: arabic, capsMode: .shiftStripped), arabicPhrase)
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: arabic, capsMode: .lowercased), arabicPhrase)
    }

    func testArabicShiftedRenderingIsDiacriticJunk() throws {
        let arabic = try LayoutFixtures.layout(LayoutFixtures.arabicSourceID)
        let keys = try keys(latinPhrase)

        // KeycodeMap models uppercase as shift, but the real capture carried
        // caps lock. The shifted Arabic layer is diacritics, so `.asTyped`
        // must not be mistaken for the intended text.
        let shifted = LayoutRenderer.render(keys, layout: arabic, capsMode: .asTyped)
        XCTAssertFalse(shifted.isEmpty)
        XCTAssertNotEqual(shifted, arabicPhrase)
    }

    func testEmptyRateFlagsUnproducibleKeys() throws {
        let arabic = try LayoutFixtures.layout(LayoutFixtures.arabicSourceID)
        let keys = try keys(latinPhrase)

        XCTAssertEqual(
            LayoutRenderer.emptyRate(keys, layout: arabic, capsMode: .shiftStripped), 0,
            accuracy: 0.0001)
        XCTAssertGreaterThan(
            LayoutRenderer.emptyRate(keys, layout: arabic, capsMode: .asTyped), 0)
    }

    func testEmptyRateOfEmptySequenceIsZero() throws {
        let abc = try LayoutFixtures.layout(LayoutFixtures.abcSourceID)
        XCTAssertEqual(LayoutRenderer.emptyRate([], layout: abc, capsMode: .asTyped), 0)
        XCTAssertEqual(LayoutRenderer.render([], layout: abc, capsMode: .asTyped), "")
    }

    func testAbcRoundTripsLowercaseText() throws {
        let abc = try LayoutFixtures.layout(LayoutFixtures.abcSourceID)
        let keys = try keys("hello world")

        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .asTyped), "hello world")
    }

    func testAbcHonoursShiftPerCapsMode() throws {
        let abc = try LayoutFixtures.layout(LayoutFixtures.abcSourceID)
        let keys = try keys("HELLO")

        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .asTyped), "HELLO")
        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .shiftStripped), "hello")
        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .lowercased), "hello")
    }

    func testCapsLockIsKeptByShiftStrippedAndDroppedByLowercased() throws {
        let abc = try LayoutFixtures.layout(LayoutFixtures.abcSourceID)
        let keys = try keys("hello").map {
            CapturedKey(
                keycode: $0.keycode,
                flags: [.capsLock],
                producedText: $0.producedText,
                keyboardType: $0.keyboardType)
        }

        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .asTyped), "HELLO")
        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .shiftStripped), "HELLO")
        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .lowercased), "hello")
    }

    /// The same keycodes read as Arabic under one layout and as Latin gibberish
    /// under the other: that inverse is the whole basis of the fix.
    func testSameKeycodesRenderBothDirections() throws {
        let abc = try LayoutFixtures.layout(LayoutFixtures.abcSourceID)
        let arabic = try LayoutFixtures.layout(LayoutFixtures.arabicSourceID)
        let keys = try keys("hc mv;")

        XCTAssertEqual(LayoutRenderer.render(keys, layout: arabic, capsMode: .asTyped), "اذ ودك")
        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc, capsMode: .asTyped), "hc mv;")
    }

    func testFixtureCarriesExpectedLanguageCodes() throws {
        XCTAssertEqual(try LayoutFixtures.layout(LayoutFixtures.abcSourceID).language, .english)
        XCTAssertEqual(try LayoutFixtures.layout(LayoutFixtures.arabicSourceID).language, .arabic)
        XCTAssertEqual(LayoutLanguage(languageCode: "fr"), .other("fr"))
    }
}
