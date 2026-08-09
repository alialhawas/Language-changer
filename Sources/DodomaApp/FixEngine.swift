import Carbon.HIToolbox
import CoreGraphics
import DodomaCore
import Foundation

/// Why a fix could not be written to the screen.
enum FixError: Error, CustomStringConvertible {
    /// A command chord was in progress; rewriting under it would send the
    /// deletes to whatever the chord is doing.
    case modifierHeld
    /// The target input source is no longer enabled.
    case layoutNotFound
    /// CoreGraphics refused to make an event, which in practice means the
    /// Accessibility grant went away mid-sequence.
    case eventCreationFailed

    var description: String {
        switch self {
        case .modifierHeld: return "modifierHeld"
        case .layoutNotFound: return "layoutNotFound"
        case .eventCreationFailed: return "eventCreationFailed"
        }
    }
}

/// The destructive half of Dodoma: deletes what the user typed, types the
/// corrected text in its place and switches the keyboard layout.
///
/// Everything runs on one serial queue, off the pipeline queue, because the
/// sequence deliberately sleeps between events — a burst posted with no gaps
/// arrives out of order in several apps, and the receiving app needs run-loop
/// turns to process each keystroke.
///
/// There is no rollback. If the sequence fails halfway the screen is left in
/// whatever state it reached and the failure is logged as a fault with the
/// counts; undo is M7's problem and a silent half-repair would be worse than a
/// visible one.
final class FixEngine {
    /// Every delay in the sequence, in one place, so per-app tuning later is a
    /// table lookup rather than a hunt through the injector.
    enum Timing {
        /// Between the individual backspace events. Apps that coalesce key
        /// events start dropping deletes below roughly 8 ms.
        static let backspaceInterval: TimeInterval = 0.010
        /// Let the app settle after the burst before text arrives.
        static let postDeleteGap: TimeInterval = 0.040
        /// Between the events of the insertion.
        static let insertInterval: TimeInterval = 0.006
        /// Wait between modifier pre-flight checks.
        static let modifierRetryDelay: TimeInterval = 0.150
        /// Pre-flight retries before giving up (so four checks in total).
        static let modifierRetryLimit = 3
        /// How long to wait for the input source change to be confirmed.
        static let layoutSwitchTimeout: TimeInterval = 0.250
        /// UTF-16 units per injected chunk.
        static let insertChunkLimit = 20
    }

    /// Modifiers that mean the keystroke stream is not plain typing.
    ///
    /// Caps Lock is deliberately absent: typing Arabic through the English
    /// layout with Caps Lock on is the single most common way to produce the
    /// text this app exists to fix, so treating it as a blocker would disable
    /// the product.
    private static let blockingModifiers: CGEventFlags = [
        .maskShift, .maskCommand, .maskControl, .maskAlternate,
    ]

    private let queue = DispatchQueue(label: "com.ali.dodoma.fixengine", qos: .userInitiated)

    /// Applies `fix` and reports the outcome on the engine's own queue.
    func apply(_ fix: Fix, completion: @escaping (Result<Void, FixError>) -> Void) {
        queue.async {
            completion(self.perform(fix))
        }
    }

    // MARK: - The sequence

    private func perform(_ fix: Fix) -> Result<Void, FixError> {
        if let error = waitForModifiers() { return .failure(error) }

        guard let source = makeSource() else {
            Log.fix.fault("could not create the injection event source; nothing was typed")
            return .failure(.eventCreationFailed)
        }

        var deleted = 0
        while deleted < fix.deleteCount {
            guard postBackspace(source: source) else {
                return .failure(fault(.eventCreationFailed, deleted: deleted, inserted: 0, of: fix))
            }
            deleted += 1
        }

        Thread.sleep(forTimeInterval: Timing.postDeleteGap)

        var inserted = 0
        for chunk in TextChunker.chunkUTF16(fix.insertText, max: Timing.insertChunkLimit) {
            guard postText(chunk, source: source) else {
                return .failure(
                    fault(.eventCreationFailed, deleted: deleted, inserted: inserted, of: fix))
            }
            inserted += chunk.utf16.count
        }

        // Only now: the text was injected as unicode, so it does not depend on
        // the active layout, but the *next* thing the user types does.
        if let error = selectInputSource(fix.targetLayoutID) {
            return .failure(fault(error, deleted: deleted, inserted: inserted, of: fix))
        }

        Log.fix.info(
            "fix applied: deleted \(deleted, privacy: .public), inserted \(inserted, privacy: .public) UTF-16 units, layout \(fix.targetLayoutID, privacy: .public)"
        )
        return .success(())
    }

    /// A half-applied edit is exactly what the log has to make visible.
    private func fault(_ error: FixError, deleted: Int, inserted: Int, of fix: Fix) -> FixError {
        Log.fix.fault(
            "fix failed (\(error.description, privacy: .public)) after deleting \(deleted, privacy: .public)/\(fix.deleteCount, privacy: .public) and inserting \(inserted, privacy: .public)/\(fix.insertText.utf16.count, privacy: .public) UTF-16 units; no rollback attempted"
        )
        return error
    }

    // MARK: - Pre-flight

    /// Holding a modifier turns our backspaces into something else entirely
    /// (⌥⌫ deletes a word, ⌘⌫ a line), so the sequence waits for a clear
    /// keyboard and abandons the fix rather than starting one it cannot finish.
    private func waitForModifiers() -> FixError? {
        for attempt in 0...Timing.modifierRetryLimit {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: Self.blockingModifiers) { return nil }
            if attempt < Timing.modifierRetryLimit {
                Thread.sleep(forTimeInterval: Timing.modifierRetryDelay)
            }
        }
        Log.fix.info("fix abandoned: a modifier stayed down through every retry")
        return .modifierHeld
    }

    // MARK: - Event injection

    /// Events carry `EventTapController.injectedEventMarker` so our own tap
    /// discards them instead of feeding the replacement back into the buffer.
    private func makeSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        source.userData = EventTapController.injectedEventMarker
        return source
    }

    private func postBackspace(source: CGEventSource) -> Bool {
        let keycode = CGKeyCode(Keycode.delete)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false)
        else { return false }

        post(down, then: Timing.backspaceInterval)
        post(up, then: Timing.backspaceInterval)
        return true
    }

    private func postText(_ chunk: String, source: CGEventSource) -> Bool {
        var units = Array(chunk.utf16)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }

        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

        post(down, then: Timing.insertInterval)
        post(up, then: Timing.insertInterval)
        return true
    }

    /// Clearing the flags matters: the event source inherits the live modifier
    /// state, and a stale Caps Lock or Shift bit would change what the
    /// receiving app makes of the keystroke.
    private func post(_ event: CGEvent, then pause: TimeInterval) {
        event.flags = []
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: pause)
    }

    // MARK: - Input source

    /// Switches the keyboard layout and waits for the confirmation
    /// notification, so the caller can rely on the next keystroke being typed
    /// in the language the text is now in. Returns nil on success.
    private func selectInputSource(_ sourceID: String) -> FixError? {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        let confirmed = DispatchSemaphore(value: 0)

        var observer: NSObjectProtocol?
        var status: OSStatus = noErr
        var found = false

        // TIS is documented as main-thread only. Blocking this queue on the
        // main thread is safe: nothing on the main thread ever waits on the
        // fix engine.
        DispatchQueue.main.sync {
            guard let source = Self.inputSource(withID: sourceID) else { return }
            found = true
            observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                confirmed.signal()
            }
            status = TISSelectInputSource(source)
        }
        defer {
            if let observer {
                DispatchQueue.main.async { center.removeObserver(observer) }
            }
        }

        guard found else {
            Log.fix.error("input source \(sourceID, privacy: .public) is not enabled")
            return .layoutNotFound
        }
        guard status == noErr else {
            Log.fix.error(
                "TISSelectInputSource(\(sourceID, privacy: .public)) failed with \(status, privacy: .public)"
            )
            return .layoutNotFound
        }
        if confirmed.wait(timeout: .now() + Timing.layoutSwitchTimeout) == .timedOut {
            // The selection call succeeded, so the switch is almost certainly
            // in flight; the notification is a courtesy, not a precondition.
            Log.fix.debug("input source switch was not confirmed within the timeout")
        }
        return nil
    }

    private static func inputSource(withID sourceID: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
        guard
            let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as NSArray?
                as? [TISInputSource]
        else { return nil }
        return sources.first
    }
}
