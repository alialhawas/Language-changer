import Foundation

/// A monotonic count of the inputs the app has seen, readable from a thread
/// other than the one that bumps it.
///
/// It exists because two different pieces of work are decided at one moment and
/// carried out at a later one, and both become wrong if the user typed in
/// between:
///
/// - the accessibility gate, which asks about the focused field and then acts
///   on an answer that arrives milliseconds later;
/// - the caret verification, which is read *before* the injector's modifier
///   pre-flight and is therefore up to that pre-flight's whole duration stale by
///   the time the first backspace is posted.
///
/// Both take a serial when they decide and compare it when they act. Anything
/// at all — a keystroke, a click, an app switch — moves the number and cancels
/// the work, which is the conservative direction: the cost of a false cancel is
/// one more quiet period, the cost of a false proceed is deleted text.
///
/// The bumps all happen on one queue; the reads do not, which is the whole
/// reason this is a lock rather than a plain `var`.
public final class InputSerial: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    /// Records one input and returns the new value.
    @discardableResult
    public func bump() -> UInt64 {
        lock.lock()
        // Wrapping is deliberate: only equality is ever asked of this, and a
        // trap after 2^64 keystrokes would be a strange way to lose a session.
        value &+= 1
        let bumped = value
        lock.unlock()
        return bumped
    }

    public var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// True when any input has arrived since `serial` was taken.
    public func hasMoved(since serial: UInt64) -> Bool {
        current != serial
    }
}
