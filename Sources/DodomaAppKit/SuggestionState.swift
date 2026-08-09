import CoreGraphics
import Foundation

/// The handful of bytes the event tap thread is allowed to know about the
/// suggestion panel.
///
/// The tap callback runs on its own run loop and is on the critical path of
/// every keystroke on the machine, so it may not ask the main thread anything
/// and may not take a queue hop to find out whether a panel is up. It reads this
/// struct instead: one uncontended lock, three fields, no allocation.
///
/// Written by the panel controller on the main thread and read by the tap thread
/// and by the pipeline queue, which is what makes the lock necessary.
final class SuggestionState: @unchecked Sendable {
    struct Snapshot: Equatable {
        var visible = false
        /// False once the tap watchdog has tripped. The panel keeps working;
        /// only the swallowing stops, so Tab and Escape go back to being the
        /// application's keys and the card is accepted by clicking it.
        var consumesKeys = true
        /// The card's rectangle in *display* coordinates — top-left origin —
        /// because that is what `CGEvent.location` reports and the conversion
        /// belongs on the main thread, not in the tap callback.
        var panelFrame = CGRect.zero
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    var isVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.visible
    }

    var consumesKeys: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.consumesKeys
    }

    /// - Parameter displayFrame: the card's frame in display coordinates.
    func show(displayFrame: CGRect) {
        lock.lock()
        state.visible = true
        state.panelFrame = displayFrame
        lock.unlock()
    }

    func hide() {
        lock.lock()
        state.visible = false
        state.panelFrame = .zero
        lock.unlock()
    }

    func setConsumesKeys(_ consumes: Bool) {
        lock.lock()
        state.consumesKeys = consumes
        lock.unlock()
    }
}
