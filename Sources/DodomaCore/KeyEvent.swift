import Foundation

/// Modifier flags relevant to typing, decoupled from CoreGraphics' `CGEventFlags`
/// so that `DodomaCore` stays free of AppKit and CoreGraphics.
/// The app layer translates `CGEventFlags` into this type at the event-tap boundary.
public struct KeyFlags: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = KeyFlags(rawValue: 1 << 0)
    public static let control = KeyFlags(rawValue: 1 << 1)
    public static let option = KeyFlags(rawValue: 1 << 2)
    public static let command = KeyFlags(rawValue: 1 << 3)
    public static let capsLock = KeyFlags(rawValue: 1 << 4)

    /// Modifiers that make a keystroke a command chord rather than typing.
    public static let chordModifiers: KeyFlags = [.command, .control]

    /// Human-readable rendering for the debug window, e.g. "⌘⇧".
    public var symbols: String {
        var out = ""
        if contains(.capsLock) { out += "⇪" }
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A single keystroke observed by the event tap.
public struct CapturedKey: Equatable, Hashable, Sendable {
    /// Hardware, layout-independent key code (a `CGKeyCode` value).
    public let keycode: UInt16
    public let flags: KeyFlags
    /// The text the event actually produced under the active input source.
    public let producedText: String
    /// The physical keyboard type reported by the event.
    public let keyboardType: UInt32
    /// Seconds since the reference date, captured when the event was observed.
    public let timestamp: TimeInterval

    public init(
        keycode: UInt16,
        flags: KeyFlags = [],
        producedText: String,
        keyboardType: UInt32 = 0,
        timestamp: TimeInterval = 0
    ) {
        self.keycode = keycode
        self.flags = flags
        self.producedText = producedText
        self.keyboardType = keyboardType
        self.timestamp = timestamp
    }
}

/// Hardware key codes referenced by the buffer reset policy.
/// These are layout independent: keycode 36 is Return on every keyboard layout.
public enum Keycode {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let keypadEnter: UInt16 = 76
    public static let home: UInt16 = 115
    public static let pageUp: UInt16 = 116
    public static let forwardDelete: UInt16 = 117
    public static let end: UInt16 = 119
    public static let pageDown: UInt16 = 121
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
}
