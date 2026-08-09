import XCTest

@testable import DodomaCore

final class LayoutRendererTests: XCTestCase {
    /// Reference capture: this Latin text typed with Caps Lock on is what the
    /// user meant to type in Arabic.
    private let latinPhrase = "HC MV; HKH HSMDIH HGDML"
    private let arabicPhrase = "اذ ودك انا اسويها اليوم"

    /// US/ANSI keycode for `e`; with option it arms the acute dead key on ABC.
    private let eKeycode: UInt16 = 14

    func testArabicRenderingIgnoresCaseModifiers() throws {
        let arabic = try LayoutFixtures.arabic()
        let keys = try arabic.keys(latinPhrase)

        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: arabic.layout, capsMode: .shiftStripped),
            arabicPhrase)
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: arabic.layout, capsMode: .lowercased), arabicPhrase)
    }

    func testArabicShiftedRenderingIsDiacriticJunk() throws {
        let arabic = try LayoutFixtures.arabic()
        let keys = try arabic.keys(latinPhrase)

        // KeycodeMap models uppercase as shift, but the real capture carried
        // caps lock. The shifted Arabic layer is diacritics, so `.asTyped`
        // must not be mistaken for the intended text.
        let shifted = LayoutRenderer.render(keys, layout: arabic.layout, capsMode: .asTyped)
        XCTAssertFalse(shifted.isEmpty)
        XCTAssertNotEqual(shifted, arabicPhrase)
    }

    func testEmptyRateCountsGenuinelyUnmappedKeys() throws {
        let arabic = try LayoutFixtures.arabic()
        let keys = try arabic.keys(latinPhrase)

        XCTAssertEqual(
            LayoutRenderer.emptyRate(keys, layout: arabic.layout, capsMode: .shiftStripped), 0,
            accuracy: 0.0001)
        // Shift+G (keycode 5) has nothing on the Arabic layout, and the Arabic
        // layout has no dead keys at all, so exactly one of 23 keys is empty.
        XCTAssertEqual(
            LayoutRenderer.emptyRate(keys, layout: arabic.layout, capsMode: .asTyped),
            1.0 / 23.0, accuracy: 0.0001)
    }

    /// Regression: a dead key is pending, not unproducible. Counting it as
    /// empty would poison the reject signal for perfectly valid renders.
    func testEmptyRateDoesNotCountDeadKeys() throws {
        let abc = try LayoutFixtures.abc()
        let keys = [abc.key(eKeycode, [.option]), abc.key(eKeycode)]

        let rendered = LayoutRenderer.renderKeys(keys, layout: abc.layout, capsMode: .asTyped)
        XCTAssertEqual(rendered.map(\.text), ["", "é"])
        XCTAssertEqual(rendered.map(\.isDeadKey), [true, false])
        XCTAssertEqual(rendered.map(\.isUnproducible), [false, false])
        XCTAssertEqual(LayoutRenderer.emptyRate(keys, layout: abc.layout, capsMode: .asTyped), 0)
    }

    /// Dead keys must compose: the rendered string is what the user would have
    /// seen under the right layout, which is exactly what M4 will type back.
    func testDeadKeyComposesWithTheFollowingKey() throws {
        let abc = try LayoutFixtures.abc()
        let keys = [abc.key(eKeycode, [.option]), abc.key(eKeycode)]

        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), "é")
    }

    /// A sequence ending on a dead key is one glyph short of the screen, where
    /// macOS shows the pending accent in its spacing form.
    func testTrailingDeadKeyFlushesToItsSpacingForm() throws {
        let abc = try LayoutFixtures.abc()
        let keys = [abc.key(eKeycode, [.option])]

        let rendered = LayoutRenderer.renderKeys(keys, layout: abc.layout, capsMode: .asTyped)
        XCTAssertEqual(rendered.map(\.text), ["\u{00B4}"])
        XCTAssertTrue(rendered[0].isDeadKey)
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), "\u{00B4}")
        XCTAssertEqual(LayoutRenderer.emptyRate(keys, layout: abc.layout, capsMode: .asTyped), 0)
    }

    func testTrailingDeadKeyFlushIsNotAppliedAfterComposition() throws {
        let abc = try LayoutFixtures.abc()
        let keys = try abc.keys("ae")

        // No dead key was armed, so nothing may be appended.
        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), "ae")
    }

    func testOptionStaysAppliedAcrossEveryCapsMode() throws {
        let abc = try LayoutFixtures.abc()
        let keys = [abc.key(eKeycode, [.option, .shift, .capsLock])]

        // Option survives all three modes, so the acute dead key stays armed
        // and flushes to its spacing form regardless of the case handling.
        for capsMode in CapsMode.allCases {
            XCTAssertEqual(
                LayoutRenderer.render(keys, layout: abc.layout, capsMode: capsMode), "\u{00B4}",
                "capsMode \(capsMode.rawValue)")
        }
    }

    func testEmptyRateOfEmptySequenceIsZero() throws {
        let abc = try LayoutFixtures.abc()
        XCTAssertEqual(LayoutRenderer.emptyRate([], layout: abc.layout, capsMode: .asTyped), 0)
        XCTAssertEqual(LayoutRenderer.render([], layout: abc.layout, capsMode: .asTyped), "")
        XCTAssertEqual(LayoutRenderer.renderKeys([], layout: abc.layout, capsMode: .asTyped), [])
    }

    func testAbcRoundTripsLowercaseText() throws {
        let abc = try LayoutFixtures.abc()
        let keys = try abc.keys("hello world")

        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), "hello world")
    }

    func testAbcHonoursShiftPerCapsMode() throws {
        let abc = try LayoutFixtures.abc()
        let keys = try abc.keys("HELLO")

        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), "HELLO")
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: abc.layout, capsMode: .shiftStripped), "hello")
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: abc.layout, capsMode: .lowercased), "hello")
    }

    func testCapsLockIsKeptByShiftStrippedAndDroppedByLowercased() throws {
        let abc = try LayoutFixtures.abc()
        let keys = try abc.keys("hello").map {
            CapturedKey(
                keycode: $0.keycode,
                flags: [.capsLock],
                producedText: $0.producedText,
                keyboardType: $0.keyboardType)
        }

        XCTAssertEqual(LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), "HELLO")
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: abc.layout, capsMode: .shiftStripped), "HELLO")
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: abc.layout, capsMode: .lowercased), "hello")
    }

    /// The same keycodes read as Arabic under one layout and as Latin gibberish
    /// under the other: that inverse is the whole basis of the fix.
    func testSameKeycodesRenderBothDirections() throws {
        let abc = try LayoutFixtures.abc()
        let arabic = try LayoutFixtures.arabic()
        let keys = try abc.keys("hc mv;")

        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: arabic.layout, capsMode: .asTyped), "اذ ودك")
        XCTAssertEqual(
            LayoutRenderer.render(keys, layout: abc.layout, capsMode: .asTyped), "hc mv;")
    }

    func testFixtureCarriesExpectedLanguageCodesAndKeyboardType() throws {
        let abc = try LayoutFixtures.abc()
        let arabic = try LayoutFixtures.arabic()

        XCTAssertEqual(abc.layout.language, .english)
        XCTAssertEqual(arabic.layout.language, .arabic)
        XCTAssertEqual(LayoutLanguage(languageCode: "fr"), .other("fr"))
        XCTAssertNotEqual(abc.keyboardType, 0)
        XCTAssertEqual(abc.keyboardType, arabic.keyboardType)
    }
}
