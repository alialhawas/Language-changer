import CoreGraphics
import XCTest

@testable import DodomaCore

/// Whether the event tap consumes a key is the one place Dodoma can break
/// somebody's keyboard, so the rule is enumerated rather than sampled.
final class SuggestionKeyDispositionTests: XCTestCase {
    private let ordinary: UInt16 = 0  // "a"

    func testNothingIsEverSwallowedWhileNoPanelIsUp() {
        for keycode in [SuggestionKeys.acceptKeycode, SuggestionKeys.dismissKeycode, ordinary] {
            XCTAssertEqual(
                SuggestionKeys.disposition(visible: false, consumesKeys: true, keycode: keycode),
                .pass,
                "keycode \(keycode)")
        }
    }

    func testThePanelKeysAreSwallowedWhileItIsUp() {
        XCTAssertEqual(
            SuggestionKeys.disposition(
                visible: true, consumesKeys: true, keycode: SuggestionKeys.acceptKeycode),
            .swallowAndAccept)
        XCTAssertEqual(
            SuggestionKeys.disposition(
                visible: true, consumesKeys: true, keycode: SuggestionKeys.dismissKeycode),
            .swallowAndDismiss)
    }

    /// Typing through the panel is how a suggestion is declined, so the key has
    /// to reach the application.
    func testOrdinaryTypingPassesThroughAndTakesThePanelDown() {
        XCTAssertEqual(
            SuggestionKeys.disposition(visible: true, consumesKeys: true, keycode: ordinary),
            .dismissAndPass)
        XCTAssertEqual(
            SuggestionKeys.disposition(
                visible: true, consumesKeys: true, keycode: Keycode.returnKey),
            .dismissAndPass)
        XCTAssertEqual(
            SuggestionKeys.disposition(visible: true, consumesKeys: true, keycode: Keycode.delete),
            .dismissAndPass)
    }

    /// After the watchdog trips nothing is consumed at all — including the
    /// panel's own keys, which go back to being the application's.
    func testTheDegradedTapSwallowsNothing() {
        for keycode in [SuggestionKeys.acceptKeycode, SuggestionKeys.dismissKeycode, ordinary] {
            XCTAssertEqual(
                SuggestionKeys.disposition(visible: true, consumesKeys: false, keycode: keycode),
                .dismissAndPass,
                "keycode \(keycode)")
        }
    }

    func testTheAcceptKeyIsTabAndTheDismissKeyIsEscape() {
        XCTAssertEqual(SuggestionKeys.acceptKeycode, Keycode.tab)
        XCTAssertEqual(SuggestionKeys.dismissKeycode, Keycode.escape)
    }
}

final class SuggestionMouseDispositionTests: XCTestCase {
    private let card = CGRect(x: 200, y: 300, width: 240, height: 70)

    func testAClickOnTheCardAccepts() {
        XCTAssertEqual(
            SuggestionKeys.mouseDisposition(
                visible: true, panelFrame: card, location: CGPoint(x: 300, y: 320)),
            .accept)
    }

    func testAClickAnywhereElseDismissesAndIsStillAClick() {
        XCTAssertEqual(
            SuggestionKeys.mouseDisposition(
                visible: true, panelFrame: card, location: CGPoint(x: 100, y: 100)),
            .dismissAndPass)
        XCTAssertEqual(
            SuggestionKeys.mouseDisposition(
                visible: true, panelFrame: card, location: CGPoint(x: 441, y: 320)),
            .dismissAndPass,
            "just past the right edge")
    }

    func testWithNoPanelUpEveryClickIsOrdinary() {
        XCTAssertEqual(
            SuggestionKeys.mouseDisposition(
                visible: false, panelFrame: card, location: CGPoint(x: 300, y: 320)),
            .pass)
    }
}

/// The rule that stands between "the user asked for this" and a delete burst
/// measured from a caret that has since moved.
final class SuggestionAcceptanceTests: XCTestCase {
    func testAnUnmovedSerialApplies() {
        XCTAssertEqual(SuggestionKeys.acceptance(pendingSerial: 7, currentSerial: 7), .apply)
        XCTAssertEqual(SuggestionKeys.acceptance(pendingSerial: 0, currentSerial: 0), .apply)
    }

    func testAnyMovementAtAllInvalidatesTheAcceptance() {
        let cases: [(pending: UInt64, current: UInt64)] = [
            (7, 8),  // one keystroke
            (7, 12),  // a word
            (7, 6),  // the counter wrapped; only equality is ever asked of it
            (0, 1),
            (UInt64.max, 0),
        ]
        for row in cases {
            XCTAssertEqual(
                SuggestionKeys.acceptance(
                    pendingSerial: row.pending, currentSerial: row.current),
                .stale,
                "pending=\(row.pending) current=\(row.current)")
        }
    }

    func testAnAcceptWithNothingPendingIsGone() {
        XCTAssertEqual(SuggestionKeys.acceptance(pendingSerial: nil, currentSerial: 3), .gone)
    }
}

/// Without suppression a dismissed suggestion returns one second later, for
/// ever: the dismissal does not reset the buffer, because the text really is
/// still on screen.
final class SuggestionSuppressionTests: XCTestCase {
    private let chat = "com.tinyspeck.slackmacgap"
    private let editor = "com.apple.TextEdit"

    func testNothingIsSuppressedToBeginWith() {
        let set = SuggestionSuppression()
        XCTAssertFalse(set.isSuppressed(text: "hgsghl", bundleID: chat, at: 0))
    }

    func testTheSameTextInTheSameAppIsSuppressedForTheWholeWindow() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl", bundleID: chat, at: 100)
        XCTAssertTrue(set.isSuppressed(text: "hgsghl", bundleID: chat, at: 100))
        XCTAssertTrue(set.isSuppressed(text: "hgsghl", bundleID: chat, at: 159.9))
    }

    func testTheEntryExpiresAtTheWindow() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl", bundleID: chat, at: 100)
        XCTAssertFalse(
            set.isSuppressed(text: "hgsghl", bundleID: chat, at: 100 + SuggestionSuppression.window)
        )
        XCTAssertFalse(set.isSuppressed(text: "hgsghl", bundleID: chat, at: 200))
    }

    /// The same word can be a mistake in a chat window and deliberate in an
    /// editor, so refusing it in one says nothing about the other.
    func testADifferentApplicationIsNotSuppressed() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl", bundleID: chat, at: 100)
        XCTAssertFalse(set.isSuppressed(text: "hgsghl", bundleID: editor, at: 101))
        XCTAssertFalse(set.isSuppressed(text: "hgsghl", bundleID: nil, at: 101))
    }

    func testADifferentTextInTheSameApplicationIsNotSuppressed() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl", bundleID: chat, at: 100)
        XCTAssertFalse(set.isSuppressed(text: "hgsghk", bundleID: chat, at: 101))
    }

    func testRecordingAgainRestartsTheWindow() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl", bundleID: chat, at: 100)
        set.record(text: "hgsghl", bundleID: chat, at: 150)
        XCTAssertTrue(set.isSuppressed(text: "hgsghl", bundleID: chat, at: 190))
    }

    /// The set is pruned on every record, so a session of many hours cannot
    /// accumulate a copy of everything the user has ever been offered.
    func testExpiredEntriesAreDroppedRatherThanAccumulated() {
        var set = SuggestionSuppression()
        for index in 0..<50 {
            set.record(text: "text\(index)", bundleID: chat, at: Double(index))
        }
        XCTAssertEqual(set.count, 50)
        set.record(text: "later", bundleID: chat, at: 1000)
        XCTAssertEqual(set.count, 1, "everything older than the window went")
    }

    /// The separator has to be something neither a bundle identifier nor typed
    /// text can contain, or two different pairs could share one key.
    func testTheKeyCannotBeForgedByConcatenation() {
        XCTAssertNotEqual(
            SuggestionSuppression.key(text: "b", bundleID: "a"),
            SuggestionSuppression.key(text: "", bundleID: "ab"))
        var set = SuggestionSuppression()
        set.record(text: "b", bundleID: "a", at: 0)
        XCTAssertFalse(set.isSuppressed(text: "", bundleID: "ab", at: 0))
    }
}
