import Foundation

/// What to do with the typed buffer once an apply has finished, succeeded or
/// not.
///
/// Two decisions, and both are easy to get subtly wrong, so they live here as
/// a pure function rather than as branches inside the pipeline:
///
/// - **Reset.** The buffer is a claim about what the user typed and what is
///   therefore on screen in front of the caret. Anything that breaks that
///   correspondence must clear it, because the next fix deletes a span counted
///   from the caret and a stale buffer would delete the wrong span. Two things
///   break it: writing to the screen ourselves, and dropping real keystrokes
///   while we were deaf. An apply that posted no events and swallowed no input
///   breaks nothing.
/// - **Re-arm.** Only worth doing when the buffer survived intact and the
///   failure was the passing kind, so the same fix can land on the next quiet
///   period without the user retyping anything.
public struct ApplyAftermath: Equatable, Sendable {
    public let resetBuffer: Bool
    public let rearmTrigger: Bool

    public init(resetBuffer: Bool, rearmTrigger: Bool) {
        self.resetBuffer = resetBuffer
        self.rearmTrigger = rearmTrigger
    }

    /// - Parameters:
    ///   - touchedNothing: the sequence posted no event at all, so the screen
    ///     is exactly as the user left it.
    ///   - droppedInput: a keystroke or click was discarded while the apply
    ///     was running. It reached the screen but not the buffer.
    ///   - transientFailure: the apply failed for a reason worth retrying
    ///     unprompted, such as a modifier that was still held down.
    ///   - bufferEmpty: there is nothing left to evaluate anyway.
    public static func decide(
        touchedNothing: Bool,
        droppedInput: Bool,
        transientFailure: Bool,
        bufferEmpty: Bool
    ) -> ApplyAftermath {
        let intact = touchedNothing && !droppedInput
        return ApplyAftermath(
            resetBuffer: !intact,
            rearmTrigger: intact && transientFailure && !bufferEmpty)
    }
}
