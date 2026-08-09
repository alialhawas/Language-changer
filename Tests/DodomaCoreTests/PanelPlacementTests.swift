import CoreGraphics
import XCTest

@testable import DodomaCore

/// The panel's geometry is the part of M6 that is wrong on somebody else's
/// display arrangement rather than on the developer's, so every rung of the
/// fallback ladder and every screen edge is pinned here.
final class PanelPlacementTests: XCTestCase {
    /// A 1440×900 primary screen with the menu bar taken off the top.
    private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let panel = CGSize(width: 240, height: 70)

    private func compute(
        anchor: CGPoint,
        screen: CGRect? = nil,
        rtl: Bool = false,
        quality: CaretQuality = .caret,
        size: CGSize? = nil
    ) -> CGRect {
        PanelPlacement.compute(
            anchor: anchor,
            panelSize: size ?? panel,
            screen: screen ?? visible,
            rtl: rtl,
            quality: quality)
    }

    // MARK: - The default

    func testTheCardHangsBelowTheCaretByTheGap() {
        let frame = compute(anchor: CGPoint(x: 300, y: 500))
        XCTAssertEqual(frame.minX, 300, "top-left is at the caret horizontally")
        XCTAssertEqual(
            frame.maxY, 500 - PanelPlacement.gap, "top edge sits one gap below the caret")
        XCTAssertEqual(frame.size, panel)
    }

    func testACaretHighOnTheScreenStillPlacesBelow() {
        let frame = compute(anchor: CGPoint(x: 10, y: 860))
        XCTAssertEqual(frame.maxY, 860 - PanelPlacement.gap)
    }

    // MARK: - Flipping

    func testACaretNearTheBottomFlipsAboveAndClearsTheTextLine() {
        // Below would put the card's bottom at 20 − 8 − 70 = −58.
        let frame = compute(anchor: CGPoint(x: 300, y: 20))
        XCTAssertEqual(
            frame.minY, 20 + PanelPlacement.gap + PanelPlacement.textLineAllowance,
            "the caret's own line has to stay readable")
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
    }

    func testAnAnchorWithNoTextLineFlipsWithTheBareGap() {
        let frame = compute(anchor: CGPoint(x: 300, y: 20), quality: .mouse)
        XCTAssertEqual(frame.minY, 20 + PanelPlacement.gap)
    }

    /// A screen too short for the card either way: staying below and clamping
    /// keeps the card next to the caret instead of flinging it to the top edge.
    func testWhenNeitherSideFitsTheCardStaysBelowAndIsClamped() {
        let cramped = CGRect(x: 0, y: 0, width: 400, height: 80)
        let frame = compute(
            anchor: CGPoint(x: 10, y: 40), screen: cramped, size: CGSize(width: 240, height: 70))
        XCTAssertEqual(frame.minY, cramped.minY)
        XCTAssertLessThanOrEqual(frame.maxY, cramped.maxY)
    }

    // MARK: - Right to left

    func testRightToLeftHangsTheCardFromItsTrailingEdge() {
        let frame = compute(anchor: CGPoint(x: 900, y: 500), rtl: true)
        XCTAssertEqual(frame.maxX, 900, "the card's right edge is at the caret")
        XCTAssertEqual(frame.minX, 900 - panel.width)
        XCTAssertEqual(frame.maxY, 500 - PanelPlacement.gap, "the vertical rule is unchanged")
    }

    func testRightToLeftNearTheLeftEdgeIsClampedRatherThanPushedOff() {
        let frame = compute(anchor: CGPoint(x: 30, y: 500), rtl: true)
        XCTAssertEqual(frame.minX, visible.minX)
    }

    // MARK: - Clamping, at all four corners

    func testEveryCornerIsClampedIntoTheVisibleFrame() {
        let corners: [(name: String, anchor: CGPoint)] = [
            ("bottom-left", CGPoint(x: visible.minX, y: visible.minY)),
            ("bottom-right", CGPoint(x: visible.maxX, y: visible.minY)),
            ("top-left", CGPoint(x: visible.minX, y: visible.maxY)),
            ("top-right", CGPoint(x: visible.maxX, y: visible.maxY)),
        ]
        for corner in corners {
            for rtl in [false, true] {
                let frame = compute(anchor: corner.anchor, rtl: rtl)
                let label = "\(corner.name) rtl=\(rtl)"
                XCTAssertGreaterThanOrEqual(frame.minX, visible.minX, label)
                XCTAssertLessThanOrEqual(frame.maxX, visible.maxX, label)
                XCTAssertGreaterThanOrEqual(frame.minY, visible.minY, label)
                XCTAssertLessThanOrEqual(frame.maxY, visible.maxY, label)
            }
        }
    }

    func testACardWiderThanTheScreenIsPinnedToTheLeadingEdge() {
        let narrow = CGRect(x: 100, y: 100, width: 200, height: 400)
        let frame = compute(
            anchor: CGPoint(x: 150, y: 300), screen: narrow, size: CGSize(width: 360, height: 70))
        XCTAssertEqual(frame.minX, narrow.minX, "the proposed text is at the leading edge")
        XCTAssertEqual(frame.width, 360, "clamping never resizes the card")
    }

    // MARK: - The fallback ladder

    func testCentringQualitiesPutTheCardOverTheAnchorRatherThanBesideIt() {
        for quality in CaretQuality.allCases {
            let frame = compute(anchor: CGPoint(x: 700, y: 500), quality: quality)
            if quality.centresOnAnchor {
                XCTAssertEqual(frame.midX, 700, accuracy: 0.001, quality.rawValue)
            } else {
                XCTAssertEqual(frame.minX, 700, quality.rawValue)
            }
        }
    }

    func testTheScreenFallbackAlwaysGoesAboveItsAnchor() {
        // The last rung anchors on the bottom edge of the visible frame, where
        // there is by definition no room below.
        let frame = compute(
            anchor: CGPoint(x: visible.midX, y: visible.minY), quality: .screenFallback)
        XCTAssertEqual(frame.minY, visible.minY + PanelPlacement.gap)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.001)
    }

    func testEveryQualityLandsInsideTheScreenFromAnyAnchor() {
        let anchors = [
            CGPoint(x: -50, y: -50), CGPoint(x: 5000, y: 5000), CGPoint(x: 700, y: 450),
            CGPoint(x: 0, y: 875),
        ]
        for quality in CaretQuality.allCases {
            for anchor in anchors {
                let frame = compute(anchor: anchor, quality: quality)
                let label = "\(quality.rawValue) at \(anchor)"
                XCTAssertTrue(visible.contains(frame.origin), label)
                XCTAssertLessThanOrEqual(frame.maxX, visible.maxX, label)
                XCTAssertLessThanOrEqual(frame.maxY, visible.maxY, label)
            }
        }
    }

    /// The three rungs that name a text position must not centre, and the one
    /// that names a screen edge must. Pinned by name so that adding a rung is a
    /// deliberate act rather than an accident.
    func testTheQualityLadderIsWhatTheArithmeticExpects() {
        XCTAssertEqual(
            CaretQuality.allCases.filter(\.centresOnAnchor), [.windowFrame, .screenFallback])
        XCTAssertEqual(CaretQuality.allCases.filter(\.prefersAbove), [.screenFallback])
        XCTAssertEqual(CaretQuality.allCases.filter(\.clearsTextLine), [.caret, .elementFrame])
    }
}

/// The conversion between the accessibility API's top-left-origin world and
/// AppKit's bottom-left-origin one. One constant, and getting it wrong puts the
/// panel off the bottom of the screen on any non-uniform display arrangement.
final class ScreenCoordinateTests: XCTestCase {
    private let primaryMaxY: CGFloat = 900

    func testAPointOnThePrimaryScreenIsReflectedAboutItsHeight() {
        let converted = ScreenCoordinates.appKitPoint(
            fromDisplay: CGPoint(x: 100, y: 200), primaryScreenMaxY: primaryMaxY)
        XCTAssertEqual(converted, CGPoint(x: 100, y: 700))
    }

    func testTheTopLeftOfThePrimaryScreenIsItsTopInAppKit() {
        let converted = ScreenCoordinates.appKitPoint(
            fromDisplay: .zero, primaryScreenMaxY: primaryMaxY)
        XCTAssertEqual(converted, CGPoint(x: 0, y: 900))
    }

    func testARectangleKeepsItsSizeAndMovesFromItsTopEdgeToItsBottomOne() {
        let caret = CGRect(x: 320, y: 140, width: 1, height: 17)
        let converted = ScreenCoordinates.appKitRect(
            fromDisplay: caret, primaryScreenMaxY: primaryMaxY)
        XCTAssertEqual(converted, CGRect(x: 320, y: 900 - 157, width: 1, height: 17))
        XCTAssertEqual(converted.minY, 743, "the caret's baseline")
    }

    /// A display above the primary one has negative display-y, which is exactly
    /// the case a single subtraction gets right and an `NSScreen.main` guess
    /// does not.
    func testASecondaryScreenAboveThePrimaryOneConvertsToCoordinatesAboveIt() {
        let onSecondary = CGRect(x: 200, y: -800, width: 2, height: 20)
        let converted = ScreenCoordinates.appKitRect(
            fromDisplay: onSecondary, primaryScreenMaxY: primaryMaxY)
        XCTAssertEqual(converted.minY, 900 + 780)
        XCTAssertGreaterThan(converted.minY, primaryMaxY)
    }

    func testASecondaryScreenLeftOfThePrimaryOneKeepsItsNegativeX() {
        let onSecondary = CGRect(x: -1600, y: 300, width: 2, height: 20)
        let converted = ScreenCoordinates.appKitRect(
            fromDisplay: onSecondary, primaryScreenMaxY: primaryMaxY)
        XCTAssertEqual(converted.minX, -1600)
        XCTAssertEqual(converted.minY, 900 - 320)
    }

    func testTheConversionIsItsOwnInverse() {
        let rect = CGRect(x: 12, y: 34, width: 56, height: 78)
        let round = ScreenCoordinates.displayRect(
            fromAppKit: ScreenCoordinates.appKitRect(
                fromDisplay: rect, primaryScreenMaxY: primaryMaxY),
            primaryScreenMaxY: primaryMaxY)
        XCTAssertEqual(round, rect)

        let point = CGPoint(x: 9, y: 11)
        XCTAssertEqual(
            ScreenCoordinates.displayPoint(
                fromAppKit: ScreenCoordinates.appKitPoint(
                    fromDisplay: point, primaryScreenMaxY: primaryMaxY),
                primaryScreenMaxY: primaryMaxY),
            point)
    }
}

final class ScreenSelectionTests: XCTestCase {
    private let laptop = ScreenFrames(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    /// A larger display to the right, its bottom aligned with the laptop's.
    private let external = ScreenFrames(
        frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415))

    func testAPointOnTheSecondDisplayPicksThatDisplay() {
        let frame = ScreenSelection.visibleFrame(
            containing: CGPoint(x: 2000, y: 1000), screens: [laptop, external])
        XCTAssertEqual(frame, external.visibleFrame)
    }

    func testAPointOnThePrimaryDisplayPicksThePrimaryOne() {
        let frame = ScreenSelection.visibleFrame(
            containing: CGPoint(x: 100, y: 100), screens: [laptop, external])
        XCTAssertEqual(frame, laptop.visibleFrame)
    }

    /// A window dragged half off the arrangement, or a stale accessibility
    /// rectangle. Giving up would mean no panel at all.
    func testAPointOffEveryScreenFallsBackToTheNearestOne() {
        let frame = ScreenSelection.visibleFrame(
            containing: CGPoint(x: 3000, y: 3000), screens: [laptop, external])
        XCTAssertEqual(frame, external.visibleFrame)
        XCTAssertEqual(
            ScreenSelection.visibleFrame(
                containing: CGPoint(x: -900, y: 100), screens: [laptop, external]),
            laptop.visibleFrame)
    }

    func testNoScreensAtAllYieldsTheCallersFallback() {
        let fallback = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(
            ScreenSelection.visibleFrame(containing: .zero, screens: [], fallback: fallback),
            fallback)
    }
}
