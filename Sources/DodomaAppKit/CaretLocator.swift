import AppKit
import ApplicationServices
import DodomaCore
import Foundation

/// Where the suggestion panel should point, and how much that answer is worth.
struct CaretAnchor: Equatable {
    /// AppKit global coordinates: bottom-left origin, y increasing upwards.
    var point: CGPoint
    var quality: CaretQuality
}

/// The display arrangement, snapshotted so it can be read off the main thread.
///
/// `NSScreen` and `NSEvent.mouseLocation` are main-thread affairs, and the
/// caret lookup runs on the accessibility queue. Taking the snapshot up front
/// costs three property reads on the main thread and lets the whole fallback
/// chain — including the two rungs that are pure geometry — run in one place.
struct ScreenGeometry {
    var screens: [ScreenFrames]
    /// The top of the primary screen in AppKit coordinates, which is the
    /// constant relating display coordinates to AppKit ones.
    var primaryMaxY: CGFloat
    /// AppKit global coordinates.
    var mouseLocation: CGPoint

    /// Main thread only.
    static func current() -> ScreenGeometry {
        var frames = NSScreen.screens.map {
            ScreenFrames(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        var primaryMaxY = frames.first?.frame.maxY ?? 0
        if frames.isEmpty {
            // No screen at all is a logged-out or headless session, where the
            // panel will never be seen. Synthesising the main display keeps the
            // arithmetic below total rather than special-cased.
            let bounds = CGDisplayBounds(CGMainDisplayID())
            frames = [ScreenFrames(frame: bounds, visibleFrame: bounds)]
            primaryMaxY = bounds.maxY
        }
        return ScreenGeometry(
            screens: frames, primaryMaxY: primaryMaxY, mouseLocation: NSEvent.mouseLocation)
    }

    /// The visible frame of the screen the point is on.
    func visibleFrame(containing point: CGPoint) -> CGRect {
        ScreenSelection.visibleFrame(
            containing: point, screens: screens, fallback: screens.first?.visibleFrame ?? .zero)
    }

    /// Rungs four and five, as one property because the choice between them is
    /// not the accessibility layer's to make: the pointer nudged clear of the
    /// cursor's hot spot, or — when the pointer is not on any screen, which is
    /// what a stale location after a display change looks like — the bottom
    /// centre of the nearest one.
    var pointerAnchor: CaretAnchor {
        guard screens.contains(where: { $0.frame.contains(mouseLocation) }) else {
            return screenAnchor
        }
        return CaretAnchor(
            point: CGPoint(x: mouseLocation.x + 16, y: mouseLocation.y - 24), quality: .mouse)
    }

    /// The last rung: the bottom-centre of the screen nearest the pointer.
    var screenAnchor: CaretAnchor {
        let frame = visibleFrame(containing: mouseLocation)
        return CaretAnchor(point: CGPoint(x: frame.midX, y: frame.minY), quality: .screenFallback)
    }
}

/// Finds the caret of another application over the accessibility API.
///
/// Every call in here is a synchronous IPC round trip into an application that
/// may be busy, exactly as in `FocusOracle`, and the same three limits apply:
/// the oracle's serial queue, a 50 ms per-element messaging timeout, and the
/// oracle's deadline over the whole lookup. `FocusOracle.locateCaret` is the
/// only supported entry point; this type does the reads and never touches a
/// queue itself.
///
/// The chain degrades one step at a time. Every rung produces *some* point, so
/// there is no "could not find the caret" outcome to handle in the caller — only
/// a `quality` that tells the placement arithmetic how literally to take it.
enum CaretLocator {
    /// Per attribute read. Shared with `FocusOracle` deliberately: the two run
    /// on the same queue and a slower budget here would stall the security
    /// check behind it.
    static let messagingTimeout = FocusOracle.messagingTimeout

    /// - Parameters:
    ///   - rightToLeftText: whether the text *already on screen* runs
    ///     right-to-left. It decides which end of a character's bounding box the
    ///     caret is at, and it is known for free: the fix's `replacedText` is
    ///     what is on screen.
    static func locate(pid: pid_t?, geometry: ScreenGeometry, rightToLeftText: Bool) -> CaretAnchor
    {
        guard let pid else { return geometry.pointerAnchor }

        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, messagingTimeout)

        guard let focused = element(application, kAXFocusedUIElementAttribute) else {
            return windowAnchor(of: application, geometry: geometry) ?? geometry.pointerAnchor
        }
        _ = AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        if let anchor = caretAnchor(
            of: focused, geometry: geometry, rightToLeftText: rightToLeftText)
        {
            return anchor
        }
        if let anchor = elementAnchor(of: focused, geometry: geometry) {
            return anchor
        }
        if let anchor = windowAnchor(of: focused, geometry: geometry)
            ?? windowAnchor(of: application, geometry: geometry)
        {
            return anchor
        }
        return geometry.pointerAnchor
    }

    // MARK: - The rungs

    /// Rung one: the bounds of the selected text range.
    ///
    /// A zero-length range — the ordinary case, a plain insertion point — is
    /// asked about directly first, because most Cocoa text views answer it with
    /// a zero-width caret rectangle, which is the best answer available. The
    /// applications that will not are asked for the character *before* the
    /// caret instead, and the caret is then the trailing edge of that box.
    private static func caretAnchor(
        of element: AXUIElement, geometry: ScreenGeometry, rightToLeftText: Bool
    ) -> CaretAnchor? {
        guard let selection = range(element, kAXSelectedTextRangeAttribute),
              selection.location >= 0
        else { return nil }

        if selection.length == 0 {
            if let rect = boundsForRange(element, CFRange(location: selection.location, length: 0))
            {
                return anchor(from: rect, geometry: geometry, atTrailingEdge: false)
            }
            guard selection.location > 0,
                  let rect = boundsForRange(
                      element, CFRange(location: selection.location - 1, length: 1))
            else { return nil }
            return anchor(
                from: rect, geometry: geometry, atTrailingEdge: true,
                rightToLeftText: rightToLeftText)
        }

        guard let rect = boundsForRange(element, selection) else { return nil }
        return anchor(
            from: rect, geometry: geometry, atTrailingEdge: true, rightToLeftText: rightToLeftText)
    }

    /// Rung two: the bottom-left corner of the focused control.
    private static func elementAnchor(of element: AXUIElement, geometry: ScreenGeometry)
        -> CaretAnchor?
    {
        guard let rect = frame(of: element), rect.width > 0 || rect.height > 0 else { return nil }
        let converted = ScreenCoordinates.appKitRect(
            fromDisplay: rect, primaryScreenMaxY: geometry.primaryMaxY)
        return CaretAnchor(
            point: CGPoint(x: converted.minX, y: converted.minY), quality: .elementFrame)
    }

    /// Rung three: the bottom-centre of the focused window.
    private static func windowAnchor(of element: AXUIElement, geometry: ScreenGeometry)
        -> CaretAnchor?
    {
        let window =
            self.element(element, kAXWindowAttribute)
            ?? self.element(element, kAXFocusedWindowAttribute)
        guard let window else { return nil }
        _ = AXUIElementSetMessagingTimeout(window, messagingTimeout)
        guard let rect = frame(of: window), rect.height > 0 else { return nil }
        let converted = ScreenCoordinates.appKitRect(
            fromDisplay: rect, primaryScreenMaxY: geometry.primaryMaxY)
        return CaretAnchor(
            point: CGPoint(x: converted.midX, y: converted.minY), quality: .windowFrame)
    }

    /// Accessibility rectangles are in display coordinates, so the caret's
    /// baseline is the *bottom* of the converted rectangle.
    private static func anchor(
        from displayRect: CGRect,
        geometry: ScreenGeometry,
        atTrailingEdge: Bool,
        rightToLeftText: Bool = false
    ) -> CaretAnchor {
        let rect = ScreenCoordinates.appKitRect(
            fromDisplay: displayRect, primaryScreenMaxY: geometry.primaryMaxY)
        let x: CGFloat
        if atTrailingEdge {
            x = rightToLeftText ? rect.minX : rect.maxX
        } else {
            x = rect.minX
        }
        return CaretAnchor(point: CGPoint(x: x, y: rect.minY), quality: .caret)
    }

    // MARK: - Attribute helpers

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    private static func boundsForRange(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, argument, &value)
                == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
        // Applications hand back garbage for ranges they do not really support:
        // an empty box, or one at the origin of the display. Neither is a caret.
        guard rect.height > 0, rect != .zero else { return nil }
        return rect
    }

    /// `AXFrame` where it exists, position plus size where it does not. Both
    /// are in display coordinates.
    ///
    /// `AXFrame` has no `kAX…` constant in the Swift overlay — it is one of the
    /// attributes AppKit answers but the headers never named — so it is spelt
    /// out. The position/size pair is the documented equivalent and every
    /// element that answers one answers the other.
    private static let frameAttribute = "AXFrame"

    private static func frame(of element: AXUIElement) -> CGRect? {
        if let rect = rect(element, frameAttribute) { return rect }
        guard
            let origin = point(element, kAXPositionAttribute),
            let size = size(element, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The three unwrappers are written out rather than made generic: the
    /// generic form hands `AXValueGetValue` a pointer to a type parameter,
    /// which the compiler rightly warns about.
    private static func rect(_ element: AXUIElement, _ attribute: String) -> CGRect? {
        guard let value = axValue(element, attribute) else { return nil }
        var result = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &result) else { return nil }
        return result
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &result) else { return nil }
        return result
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &result) else { return nil }
        return result
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
