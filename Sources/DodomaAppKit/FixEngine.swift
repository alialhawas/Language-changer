import Carbon.HIToolbox
import CoreGraphics
import DodomaCore
import Foundation

/// Why a fix could not be written to the screen.
enum FixError: Error, CustomStringConvertible {
    /// A command chord was in progress; rewriting under it would send the
    /// deletes to whatever the chord is doing.
    case modifierHeld
    /// The frontmost application is no longer the one the decision was made
    /// for. Everything the safety layer says about which apps may be rewritten
    /// is about *that* app, so the sequence must not continue into another one.
    case frontmostChanged
    /// The target input source is no longer enabled.
    case layoutNotFound
    /// CoreGraphics refused to make an event, which in practice means the
    /// Accessibility grant went away mid-sequence.
    case eventCreationFailed
    /// Input arrived after the caret was verified, so the verification no
    /// longer describes the screen the burst is about to delete from.
    case inputSinceVerification

    var description: String {
        switch self {
        case .modifierHeld: return "modifierHeld"
        case .frontmostChanged: return "frontmostChanged"
        case .layoutNotFound: return "layoutNotFound"
        case .eventCreationFailed: return "eventCreationFailed"
        case .inputSinceVerification: return "inputSinceVerification"
        }
    }

    /// True for the failures that say "not now" rather than "not ever": the
    /// same fix is worth attempting again on the next quiet period.
    var isTransient: Bool {
        switch self {
        case .modifierHeld, .inputSinceVerification: return true
        case .frontmostChanged, .layoutNotFound, .eventCreationFailed: return false
        }
    }
}

/// How far the sequence got before it stopped.
///
/// The caller needs this to tell "nothing happened" from "the screen was
/// changed": only the second case invalidates the typed buffer.
struct FixProgress: Equatable {
    var deletedClusters = 0
    var insertedUTF16Units = 0

    /// No event was posted, so the screen is exactly as the user left it.
    var touchedNothing: Bool { deletedClusters == 0 && insertedUTF16Units == 0 }
}

/// A failed apply, together with how much of it had already happened.
struct FixFailure: Error {
    let error: FixError
    let progress: FixProgress
}

/// The one thing the typing pipeline asks of the injector.
///
/// A protocol because the alternative, in a test, is posting real backspaces
/// into whatever window happens to be frontmost on the machine running them.
protocol FixApplying: AnyObject {
    func apply(
        _ fix: Fix,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void)
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
final class FixEngine: FixApplying {
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
    private let frontmost: FrontmostAppTracker

    /// - Parameter frontmost: the app's single tracker. Deliberately without a
    ///   default: a second tracker would mean a second activation observer and
    ///   two caches that can disagree about when the switch happened.
    init(frontmost: FrontmostAppTracker) {
        self.frontmost = frontmost
    }

    /// Applies `fix` and reports the outcome on the engine's own queue.
    ///
    /// - Parameters:
    ///   - bundleID: the app the decision was made for. The sequence refuses to
    ///     type into anything else.
    ///   - isStale: asked once, after the modifier pre-flight and before the
    ///     first destructive event. True means the caller's verification of the
    ///     text in front of the caret no longer holds. Called on the engine's
    ///     queue, so it must be safe to call off the caller's own queue.
    ///     Deliberately without a default: a caller that forgot to pass one
    ///     would silently get an unguarded delete burst.
    func apply(
        _ fix: Fix,
        in bundleID: String?,
        isStale: @escaping () -> Bool,
        completion: @escaping (Result<FixProgress, FixFailure>) -> Void
    ) {
        queue.async {
            completion(self.perform(fix, in: bundleID, isStale: isStale))
        }
    }

    // MARK: - The sequence

    private func perform(
        _ fix: Fix, in bundleID: String?, isStale: () -> Bool
    ) -> Result<FixProgress, FixFailure> {
        var progress = FixProgress()

        if let error = waitForModifiers() {
            return .failure(FixFailure(error: error, progress: progress))
        }
        // The caret was verified *before* the pre-flight above, which waits up
        // to 450 ms for a modifier to come up. Everything the user typed in
        // that window reached the screen but not the verification — the buffer
        // did not even see it, because the pipeline drops input while a fix is
        // in flight — so the span the burst is about to delete is no longer the
        // span that was checked. Nothing has been posted yet, so abandoning
        // here is free.
        if isStale() {
            Log.fix.info("fix abandoned: input arrived after the caret was verified")
            return .failure(FixFailure(error: .inputSinceVerification, progress: progress))
        }
        // The decision was made up to a second ago, and the pre-flight above may
        // have waited half a second more. A ⌘-Tab in that window would send the
        // whole burst into an app that was never allowed to be rewritten.
        guard frontmost.currentBundleID() == bundleID else {
            Log.fix.info("fix abandoned before it started: the frontmost app changed")
            return .failure(FixFailure(error: .frontmostChanged, progress: progress))
        }
        guard let source = makeSource() else {
            Log.fix.fault("could not create the injection event source; nothing was typed")
            return .failure(FixFailure(error: .eventCreationFailed, progress: progress))
        }

        // Re-checked before *every* destructive event, not just before the
        // loop: 23 clusters is nearly half a second of backspaces, and each one
        // that lands in the wrong window deletes somebody's text.
        while progress.deletedClusters < fix.deleteCount {
            guard frontmost.bundleID == bundleID else {
                return .failure(fault(.frontmostChanged, progress: progress, of: fix))
            }
            guard postBackspace(source: source) else {
                return .failure(fault(.eventCreationFailed, progress: progress, of: fix))
            }
            progress.deletedClusters += 1
        }

        Thread.sleep(forTimeInterval: Timing.postDeleteGap)

        // Authoritative check at the checkpoint between the two halves:
        // inserting Arabic into someone else's window would be worse still.
        guard frontmost.currentBundleID() == bundleID else {
            return .failure(fault(.frontmostChanged, progress: progress, of: fix))
        }

        for chunk in TextChunker.chunkUTF16(fix.insertText, max: Timing.insertChunkLimit) {
            guard frontmost.bundleID == bundleID else {
                return .failure(fault(.frontmostChanged, progress: progress, of: fix))
            }
            guard postText(chunk, source: source) else {
                return .failure(fault(.eventCreationFailed, progress: progress, of: fix))
            }
            progress.insertedUTF16Units += chunk.utf16.count
        }

        // Only now: the text was injected as unicode, so it does not depend on
        // the active layout, but the *next* thing the user types does.
        if let error = selectInputSource(fix.targetLayoutID) {
            return .failure(fault(error, progress: progress, of: fix))
        }

        Log.fix.info(
            "fix applied: deleted \(progress.deletedClusters, privacy: .public), inserted \(progress.insertedUTF16Units, privacy: .public) UTF-16 units, layout \(fix.targetLayoutID, privacy: .public)"
        )
        return .success(progress)
    }

    /// A half-applied edit is exactly what the log has to make visible.
    private func fault(_ error: FixError, progress: FixProgress, of fix: Fix) -> FixFailure {
        Log.fix.fault(
            "fix failed (\(error.description, privacy: .public)) after deleting \(progress.deletedClusters, privacy: .public)/\(fix.deleteCount, privacy: .public) and inserting \(progress.insertedUTF16Units, privacy: .public)/\(fix.insertText.utf16.count, privacy: .public) UTF-16 units; no rollback attempted"
        )
        return FixFailure(error: error, progress: progress)
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

    /// A key event with the live modifier state stripped.
    ///
    /// The event source inherits whatever modifiers are physically down, and a
    /// stale Caps Lock or Shift bit would change what the receiving app makes
    /// of the keystroke. The flags are cleared here, at creation, so that
    /// nothing touches the event after its unicode payload is set.
    private func makeKeyEvent(source: CGEventSource, keycode: CGKeyCode, down: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down)
        else { return nil }
        event.flags = []
        return event
    }

    private func postBackspace(source: CGEventSource) -> Bool {
        let keycode = CGKeyCode(Keycode.delete)
        guard
            let down = makeKeyEvent(source: source, keycode: keycode, down: true),
            let up = makeKeyEvent(source: source, keycode: keycode, down: false)
        else { return false }

        post(down, then: Timing.backspaceInterval)
        post(up, then: Timing.backspaceInterval)
        return true
    }

    private func postText(_ chunk: String, source: CGEventSource) -> Bool {
        var units = Array(chunk.utf16)
        guard
            let down = makeKeyEvent(source: source, keycode: 0, down: true),
            let up = makeKeyEvent(source: source, keycode: 0, down: false)
        else { return false }

        // Last write before posting. Setting any other field afterwards is
        // undocumented territory and has been observed to drop the payload.
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

        post(down, then: Timing.insertInterval)
        post(up, then: Timing.insertInterval)
        return true
    }

    private func post(_ event: CGEvent, then pause: TimeInterval) {
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
