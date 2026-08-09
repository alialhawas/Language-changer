import CoreGraphics
import XCTest

@testable import DodomaCore

/// Whether the event tap consumes a key is the one place Dodoma can break
/// somebody's keyboard, so the rule is enumerated rather than sampled.
final class SuggestionKeyDispositionTests: XCTestCase {
    private let ordinary: UInt16 = 0  // "a"

    private func disposition(
        visible: Bool = true, consumesKeys: Bool = true, keycode: UInt16, flags: KeyFlags = []
    ) -> KeyDisposition {
        SuggestionKeys.disposition(
            visible: visible, consumesKeys: consumesKeys, keycode: keycode, flags: flags)
    }

    func testNothingIsEverSwallowedWhileNoPanelIsUp() {
        for keycode in [SuggestionKeys.acceptKeycode, SuggestionKeys.dismissKeycode, ordinary] {
            XCTAssertEqual(
                disposition(visible: false, keycode: keycode), .pass, "keycode \(keycode)")
        }
    }

    func testTheBarePanelKeysAreSwallowedWhileItIsUp() {
        XCTAssertEqual(
            disposition(keycode: SuggestionKeys.acceptKeycode), .swallowAndAccept)
        XCTAssertEqual(
            disposition(keycode: SuggestionKeys.dismissKeycode), .swallowAndDismiss)
    }

    /// Caps Lock is how most of the text this app fixes gets typed, so it is
    /// not a blocker anywhere else and must not become one here.
    func testCapsLockDoesNotStopThePanelKeysBeingSwallowed() {
        XCTAssertEqual(
            disposition(keycode: SuggestionKeys.acceptKeycode, flags: [.capsLock]),
            .swallowAndAccept)
        XCTAssertEqual(
            disposition(keycode: SuggestionKeys.dismissKeycode, flags: [.capsLock]),
            .swallowAndDismiss)
    }

    /// The regression this parameter exists for. ⌘⇥ is the application
    /// switcher; consuming it would both break the switcher and hand the
    /// pipeline an acceptance — and a swallowed key never moves the input
    /// serial, so that acceptance would validate and a fix would be applied.
    func testAnyModifierOnAPanelKeyPassesItStraightThrough() {
        let modifiers: [(String, KeyFlags)] = [
            ("command", [.command]),
            ("control", [.control]),
            ("option", [.option]),
            ("shift", [.shift]),
            ("fn", [.fn]),
            ("command+shift", [.command, .shift]),
            ("control+option", [.control, .option]),
            ("command+capsLock", [.command, .capsLock]),
        ]
        for (name, flags) in modifiers {
            for keycode in [SuggestionKeys.acceptKeycode, SuggestionKeys.dismissKeycode] {
                XCTAssertEqual(
                    disposition(keycode: keycode, flags: flags),
                    .dismissAndPass,
                    "\(name) + keycode \(keycode)")
            }
        }
    }

    /// Pinned against the option set, so a modifier added to `KeyFlags` later
    /// has to be classified on purpose.
    func testTheBlockerSetIsEverythingButCapsLock() {
        XCTAssertEqual(
            KeyFlags.panelKeyBlockers, [.shift, .control, .option, .command, .fn])
        XCTAssertFalse(KeyFlags.panelKeyBlockers.contains(.capsLock))
    }

    /// Typing through the panel is how a suggestion is declined, so the key has
    /// to reach the application.
    func testOrdinaryTypingPassesThroughAndTakesThePanelDown() {
        XCTAssertEqual(disposition(keycode: ordinary), .dismissAndPass)
        XCTAssertEqual(disposition(keycode: Keycode.returnKey), .dismissAndPass)
        XCTAssertEqual(disposition(keycode: Keycode.delete), .dismissAndPass)
        XCTAssertEqual(disposition(keycode: ordinary, flags: [.shift]), .dismissAndPass)
    }

    /// After the watchdog trips nothing is consumed at all — including the
    /// panel's own keys, which go back to being the application's.
    func testTheDegradedTapSwallowsNothing() {
        for keycode in [SuggestionKeys.acceptKeycode, SuggestionKeys.dismissKeycode, ordinary] {
            XCTAssertEqual(
                disposition(consumesKeys: false, keycode: keycode),
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
    private let onCard = CGPoint(x: 300, y: 320)

    private func disposition(
        visible: Bool = true, primaryButton: Bool = true, location: CGPoint
    ) -> MouseDisposition {
        SuggestionKeys.mouseDisposition(
            visible: visible, primaryButton: primaryButton, panelFrame: card, location: location)
    }

    func testALeftClickOnTheCardAccepts() {
        XCTAssertEqual(disposition(location: onCard), .accept)
    }

    /// A right or middle click is a click, not an acceptance. Accepting on one
    /// would turn a context-menu attempt into a rewrite.
    func testOnlyTheLeftButtonAccepts() {
        XCTAssertEqual(disposition(primaryButton: false, location: onCard), .dismissAndPass)
    }

    func testAClickAnywhereElseDismissesAndIsStillAClick() {
        XCTAssertEqual(disposition(location: CGPoint(x: 100, y: 100)), .dismissAndPass)
        XCTAssertEqual(
            disposition(location: CGPoint(x: 441, y: 320)), .dismissAndPass,
            "just past the right edge")
    }

    func testWithNoPanelUpEveryClickIsOrdinary() {
        XCTAssertEqual(disposition(visible: false, location: onCard), .pass)
        XCTAssertEqual(disposition(visible: false, primaryButton: false, location: onCard), .pass)
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

    /// The key is a pair of fields, not a concatenation, so no two (app, text)
    /// pairs can be made to collide by moving the boundary between them.
    func testTheKeyCannotBeForgedByConcatenation() {
        var set = SuggestionSuppression()
        set.record(text: "b", bundleID: "a", at: 0)
        XCTAssertFalse(set.isSuppressed(text: "", bundleID: "ab", at: 0))
        XCTAssertFalse(set.isSuppressed(text: "ab", bundleID: "", at: 0))
    }

    // MARK: - The undo half

    /// What the guard input is built from after an undo.
    func testTextsReturnsOnlyTheLiveEntriesForOneApplication() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl ", bundleID: chat, at: 100)
        set.record(text: "hkh", bundleID: chat, at: 100)
        set.record(text: "elsewhere", bundleID: editor, at: 100)

        XCTAssertEqual(set.texts(bundleID: chat, at: 101), ["hgsghl ", "hkh"])
        XCTAssertEqual(set.texts(bundleID: editor, at: 101), ["elsewhere"])
        XCTAssertEqual(set.texts(bundleID: nil, at: 101), [])
    }

    func testTextsExpiresWithTheWindow() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl", bundleID: chat, at: 100)
        XCTAssertEqual(set.texts(bundleID: chat, at: 159.9), ["hgsghl"])
        XCTAssertEqual(
            set.texts(bundleID: chat, at: 100 + SuggestionSuppression.window), [],
            "the same boundary as isSuppressed")
    }

    /// The undone text goes in exactly as `Fix.replacedText` holds it, trailing
    /// separator and all, so that the offer check — which compares that same
    /// string — matches. Trimming for the guard happens in `TextGuards`.
    func testTheRecordedTextIsNotNormalised() {
        var set = SuggestionSuppression()
        set.record(text: "hgsghl ", bundleID: chat, at: 100)
        XCTAssertTrue(set.isSuppressed(text: "hgsghl ", bundleID: chat, at: 101))
        XCTAssertFalse(set.isSuppressed(text: "hgsghl", bundleID: chat, at: 101))
    }
}
