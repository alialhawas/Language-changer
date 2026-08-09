import CoreGraphics
import DodomaCore
import Foundation

/// Something the event tap observed, already converted to plain values so that
/// no `CGEvent` ever escapes the tap thread.
enum TapEvent {
    case key(CapturedKey)
    case mouseDown
}

/// Owns the session-wide `CGEventTap` and pumps it on a dedicated run loop thread.
///
/// The tap is a *listener*: every event is passed straight through unmodified.
/// Nothing is consumed and nothing is injected.
final class EventTapController {
    /// Marker written into `.eventSourceUserData` of events Dodoma itself will
    /// post in a later milestone. Events carrying it are ignored here so the
    /// injector can never feed its own keystrokes back into the buffer.
    static let injectedEventMarker: Int64 = 0x444F_444F

    /// Two tap disables inside this window are treated as a fault.
    private static let watchdogWindow: TimeInterval = 60
    private static let watchdogThreshold = 2

    /// How long `stop()` waits for the tap thread to leave its run loop.
    private static let threadExitTimeout: DispatchTimeInterval = .seconds(2)

    private let queue: DispatchQueue
    private let handler: (TapEvent) -> Void

    /// `tap`, `runLoopSource`, `runLoop`, `thread` and `running` are shared
    /// between the main thread (start/stop) and the tap thread (run loop body
    /// and callbacks) and are only ever touched while holding `stateLock`.
    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var running = false

    /// Signalled by the tap thread when it leaves `runTapLoop`.
    private var threadExited = DispatchSemaphore(value: 0)

    /// Touched only from the tap thread.
    private var disableTimestamps: [TimeInterval] = []

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// - Parameters:
    ///   - queue: serial queue the captured events are delivered on.
    ///   - handler: invoked on `queue` for every captured event.
    init(queue: DispatchQueue, handler: @escaping (TapEvent) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    deinit {
        // While `runTapLoop` is executing it holds a strong reference to self,
        // so deinit can only be reached once the tap thread has exited. `stop()`
        // is still called here so a controller that is dropped without an
        // explicit stop cannot leak the mach port, and it is idempotent.
        stop()
    }

    /// Creates and starts the tap. Returns false when the tap cannot be created,
    /// which is what happens while Accessibility / Input Monitoring are ungranted.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dodomaEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.tap.debug("tap creation failed (permissions not granted yet)")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Log.tap.error("failed to create run loop source for tap")
            return false
        }

        let thread = Thread { [weak self] in
            self?.runTapLoop()
        }
        thread.name = "com.ali.dodoma.eventtap"
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        tap = port
        runLoopSource = source
        self.thread = thread
        threadExited = DispatchSemaphore(value: 0)
        running = true
        stateLock.unlock()

        thread.start()

        Log.tap.info("event tap started")
        return true
    }

    /// Idempotent and safe to call from any thread. Returns only once the tap
    /// thread has left its run loop, so no callback can still be in flight when
    /// the mach port is invalidated.
    func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let port = tap
        let source = runLoopSource
        let loop = runLoop
        let exited = threadExited
        tap = nil
        runLoopSource = nil
        runLoop = nil
        stateLock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }

        if let loop {
            // The thread is inside (or about to enter) CFRunLoopRun. Wake it and
            // wait, so that no callback can be running when the port dies below.
            CFRunLoopStop(loop)
            if exited.wait(timeout: .now() + Self.threadExitTimeout) == .timedOut {
                Log.tap.error("tap thread did not exit before the teardown timeout")
            }
        }
        // If `loop` was nil the thread has not yet entered its critical section;
        // because `tap` was cleared under the same lock it will find nothing to
        // do and return immediately, so there is nothing to wait for.

        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let port {
            CFMachPortInvalidate(port)
        }

        stateLock.lock()
        thread = nil
        stateLock.unlock()

        Log.tap.info("event tap stopped")
    }

    /// Body of the dedicated tap thread. Holds a strong reference to the
    /// controller for its whole duration, which is what keeps the unretained
    /// `userInfo` pointer handed to `tapCreate` valid.
    private func runTapLoop() {
        stateLock.lock()
        let source = runLoopSource
        let port = tap
        let exited = threadExited
        let loop: CFRunLoop? = (source != nil && port != nil) ? CFRunLoopGetCurrent() : nil
        runLoop = loop
        stateLock.unlock()

        defer { exited.signal() }

        // `stop()` won the race and already tore everything down.
        guard let source, let port, let loop else { return }

        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        CFRunLoopRun()

        CFRunLoopRemoveSource(loop, source, .commonModes)
    }

    /// Snapshot of the mach port for use on the tap thread.
    private func currentTap() -> CFMachPort? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tap
    }

    // MARK: - Callback path (runs on the tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            handleTapDisabled(cause: "timeout")
            return nil
        case .tapDisabledByUserInput:
            handleTapDisabled(cause: "userInput")
            return nil
        case .keyDown:
            handleKeyDown(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isSelfInjected(event) {
                deliver(.mouseDown)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleTapDisabled(cause: String) {
        guard let tap = currentTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)

        let now = Date().timeIntervalSinceReferenceDate
        disableTimestamps.append(now)
        disableTimestamps.removeAll { now - $0 > Self.watchdogWindow }

        if disableTimestamps.count >= Self.watchdogThreshold {
            Log.tap.fault(
                "event tap disabled \(self.disableTimestamps.count, privacy: .public) times in \(Int(Self.watchdogWindow), privacy: .public)s (cause=\(cause, privacy: .public)); re-enabled"
            )
        } else {
            Log.tap.error("event tap disabled (cause=\(cause, privacy: .public)); re-enabled")
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        guard !isSelfInjected(event) else { return }

        let keycode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        // Autorepeat floods the pipeline with duplicates of the same character.
        // Backspace is the exception: held-down deletes must shrink the buffer.
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isAutorepeat && keycode != Keycode.delete { return }

        let keyboardType = UInt32(
            truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeyboardType))

        let captured = CapturedKey(
            keycode: keycode,
            flags: KeyFlags(event.flags),
            producedText: Self.unicodeString(from: event),
            keyboardType: keyboardType,
            timestamp: Date().timeIntervalSinceReferenceDate
        )
        deliver(.key(captured))
    }

    private func isSelfInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == Self.injectedEventMarker
    }

    private func deliver(_ event: TapEvent) {
        let handler = self.handler
        queue.async { handler(event) }
    }

    private static func unicodeString(from event: CGEvent) -> String {
        let maxLength = 8
        var length = 0
        var buffer = [UniChar](repeating: 0, count: maxLength)
        event.keyboardGetUnicodeString(
            maxStringLength: maxLength,
            actualStringLength: &length,
            unicodeString: &buffer)

        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: min(length, maxLength))
    }
}

/// C callback: no captures allowed, so the controller arrives via `userInfo`.
private func dodomaEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

extension KeyFlags {
    /// Boundary conversion: CoreGraphics flags are not allowed inside DodomaCore.
    init(_ flags: CGEventFlags) {
        var result: KeyFlags = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlphaShift) { result.insert(.capsLock) }
        self = result
    }
}
