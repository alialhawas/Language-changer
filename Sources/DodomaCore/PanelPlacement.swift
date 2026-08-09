import CoreGraphics
import Foundation

/// How the point the suggestion panel is anchored to was obtained.
///
/// The chain is a quality ladder, not just a list of fallbacks: each rung knows
/// less about where the text actually is than the one above it, and the
/// placement arithmetic reads the rung to decide what the point *means*. A caret
/// rect names the left edge of an insertion point; a window frame names the
/// middle of a window's bottom edge. Anchoring both the same way would put the
/// panel in the corner of the window for every application that will not report
/// a caret, which is most of the ones this feature exists for.
public enum CaretQuality: String, Equatable, Sendable, CaseIterable {
    /// Bounds of the caret, or of the character immediately before it.
    case caret
    /// Bottom-left corner of the focused control.
    case elementFrame
    /// Bottom-centre of the focused window.
    case windowFrame
    /// The mouse pointer, offset.
    case mouse
    /// Bottom-centre of the active screen. Nothing was readable at all.
    case screenFallback

    /// True when the anchor names a horizontal *centre* rather than the leading
    /// edge of a piece of text.
    public var centresOnAnchor: Bool {
        switch self {
        case .caret, .elementFrame, .mouse: return false
        case .windowFrame, .screenFallback: return true
        }
    }

    /// True when the anchor already sits on the bottom edge of the space the
    /// panel has to fit in, so there was never any room below it.
    public var prefersAbove: Bool { self == .screenFallback }

    /// True when the anchor sits on the baseline of a line of text. Flipping the
    /// panel above such an anchor has to clear the line itself, or the panel
    /// covers the very text the user is being asked about.
    public var clearsTextLine: Bool {
        switch self {
        case .caret, .elementFrame: return true
        case .windowFrame, .mouse, .screenFallback: return false
        }
    }
}

/// One display, as both of its rectangles. Snapshotted on the main thread by the
/// app layer so the geometry can be reasoned about anywhere else.
///
/// Both rectangles are in AppKit global coordinates: bottom-left origin, y
/// increasing upwards, the origin at the bottom-left of the primary screen.
public struct ScreenFrames: Equatable, Sendable {
    public let frame: CGRect
    /// The frame minus the menu bar and the Dock.
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// The single place the two global coordinate systems are reconciled.
///
/// Accessibility rectangles and `CGEvent` locations are in *display* coordinates:
/// the origin is the top-left of the primary display and y increases downwards.
/// Everything in AppKit — `NSScreen`, `NSWindow.setFrame`, `NSEvent.mouseLocation`
/// — uses the bottom-left of the primary display with y increasing upwards. The
/// two are related by one constant, the height of the primary screen, and getting
/// it wrong puts the panel off-screen on any machine whose displays are not all
/// the same height.
///
/// Both directions are the same reflection, so `appKit(fromDisplay:)` and
/// `display(fromAppKit:)` are each other's inverse.
public enum ScreenCoordinates {
    /// - Parameter primaryScreenMaxY: the top of `NSScreen.screens[0]` in AppKit
    ///   coordinates, which for the primary screen is simply its height.
    public static func appKitPoint(fromDisplay point: CGPoint, primaryScreenMaxY: CGFloat)
        -> CGPoint
    {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    public static func displayPoint(fromAppKit point: CGPoint, primaryScreenMaxY: CGFloat)
        -> CGPoint
    {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    /// A rectangle keeps its size; only the origin moves, and it moves from the
    /// rectangle's *top* edge to its bottom one.
    public static func appKitRect(fromDisplay rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    public static func displayRect(fromAppKit rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }
}

/// Which display the panel belongs on.
public enum ScreenSelection {
    /// The visible frame of the screen containing `point`.
    ///
    /// An anchor can legitimately land outside every screen — a window dragged
    /// half off the edge, a stale accessibility rectangle — so the nearest
    /// screen is used rather than giving up, and the placement then clamps into
    /// it.
    public static func visibleFrame(
        containing point: CGPoint, screens: [ScreenFrames], fallback: CGRect = .zero
    ) -> CGRect {
        guard !screens.isEmpty else { return fallback }
        if let hit = screens.first(where: { $0.frame.contains(point) }) { return hit.visibleFrame }
        let nearest = screens.min {
            squaredDistance(from: point, to: $0.frame) < squaredDistance(from: point, to: $1.frame)
        }
        return nearest?.visibleFrame ?? fallback
    }

    static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// Where the suggestion panel goes, as pure arithmetic.
///
/// Extracted from the panel for the usual reason: it is the part that is wrong
/// on somebody else's display arrangement rather than on the developer's, and a
/// unit test is the only way that ever gets exercised. Everything is in AppKit
/// global coordinates.
public enum PanelPlacement {
    /// Distance between the anchor and the nearest edge of the panel.
    public static let gap: CGFloat = 8
    /// Extra clearance when the panel is flipped above a text anchor, so the
    /// card does not cover the line the caret is on. An estimate: the
    /// accessibility API gives a caret position, not a line height.
    public static let textLineAllowance: CGFloat = 18

    /// - Parameters:
    ///   - anchor: the caret, in AppKit global coordinates.
    ///   - panelSize: the size the card wants to be.
    ///   - screen: the visible frame of the screen the anchor is on.
    ///   - rtl: true when the proposed text is right-to-left, in which case the
    ///     card's trailing edge is what the reader's eye starts from and the
    ///     panel is hung from its top-right corner instead of its top-left.
    public static func compute(
        anchor: CGPoint,
        panelSize: CGSize,
        screen: CGRect,
        rtl: Bool,
        quality: CaretQuality
    ) -> CGRect {
        let origin = CGPoint(
            x: horizontalOrigin(anchor: anchor, width: panelSize.width, rtl: rtl, quality: quality),
            y: verticalOrigin(
                anchor: anchor, height: panelSize.height, screen: screen, quality: quality))
        return clamp(CGRect(origin: origin, size: panelSize), into: screen)
    }

    private static func horizontalOrigin(
        anchor: CGPoint, width: CGFloat, rtl: Bool, quality: CaretQuality
    ) -> CGFloat {
        if quality.centresOnAnchor { return anchor.x - width / 2 }
        return rtl ? anchor.x - width : anchor.x
    }

    private static func verticalOrigin(
        anchor: CGPoint, height: CGFloat, screen: CGRect, quality: CaretQuality
    ) -> CGFloat {
        let below = anchor.y - gap - height
        let above = anchor.y + (quality.clearsTextLine ? gap + textLineAllowance : gap)
        let fitsBelow = below >= screen.minY
        let fitsAbove = above + height <= screen.maxY

        if quality.prefersAbove { return fitsAbove ? above : below }
        if fitsBelow { return below }
        // Below is off the bottom of the screen. Above only wins if the card
        // fits there whole; otherwise stay below and let the clamp deal with
        // it, because a panel pinned to the bottom edge is at least near the
        // caret, while one pinned to the top edge is nowhere near anything.
        return fitsAbove ? above : below
    }

    /// Pushes the rectangle inside `screen`. A card larger than the screen is
    /// pinned to the bottom-left rather than centred: the top-left of the card
    /// is where the proposed text is, and that is the part worth keeping.
    static func clamp(_ rect: CGRect, into screen: CGRect) -> CGRect {
        let maxX = max(screen.minX, screen.maxX - rect.width)
        let maxY = max(screen.minY, screen.maxY - rect.height)
        return CGRect(
            x: min(max(rect.minX, screen.minX), maxX),
            y: min(max(rect.minY, screen.minY), maxY),
            width: rect.width,
            height: rect.height)
    }
}
