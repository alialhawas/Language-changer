import Foundation

/// A snapshot of an enabled keyboard input source, including the `uchr` table
/// needed to translate hardware keycodes into text.
///
/// The `uchr` bytes are copied out of the Text Input Source at enumeration time
/// so the value stays valid after the source is released or disabled.
public struct KeyboardLayout: Equatable, Hashable, Sendable {
    /// e.g. `com.apple.keylayout.Arabic`.
    public let sourceID: String
    public let localizedName: String
    /// First entry of the source's language list, e.g. `ar`, `en`.
    public let languageCode: String
    /// Raw `UCKeyboardLayout` table bytes.
    public let uchrData: Data

    public init(sourceID: String, localizedName: String, languageCode: String, uchrData: Data) {
        self.sourceID = sourceID
        self.localizedName = localizedName
        self.languageCode = languageCode
        self.uchrData = uchrData
    }

    public var language: LayoutLanguage {
        LayoutLanguage(languageCode: languageCode)
    }
}

/// The two languages Dodoma arbitrates between, plus an escape hatch for
/// everything else the user may have enabled.
public enum LayoutLanguage: Equatable, Hashable, Sendable {
    case arabic
    case english
    case other(String)

    public init(languageCode: String) {
        if languageCode.hasPrefix("ar") {
            self = .arabic
        } else if languageCode.hasPrefix("en") {
            self = .english
        } else {
            self = .other(languageCode)
        }
    }
}

/// Serializable form of a `KeyboardLayout`, used to snapshot the layouts of
/// this machine into a test fixture so rendering tests do not depend on which
/// input sources happen to be enabled where the tests run.
public struct LayoutFixture: Codable, Equatable, Sendable {
    public let sourceID: String
    public let languageCode: String
    /// `LMGetKbdType()` of the machine that produced the snapshot. A `uchr`
    /// table carries several keyboard-type ranges (ANSI, ISO, JIS) that
    /// disagree about punctuation, so the table is only reproducible together
    /// with the type it was captured against.
    public let keyboardType: UInt32
    public let uchrBase64: String

    public init(
        sourceID: String, languageCode: String, keyboardType: UInt32, uchrBase64: String
    ) {
        self.sourceID = sourceID
        self.languageCode = languageCode
        self.keyboardType = keyboardType
        self.uchrBase64 = uchrBase64
    }

    public init(layout: KeyboardLayout, keyboardType: UInt32) {
        self.init(
            sourceID: layout.sourceID,
            languageCode: layout.languageCode,
            keyboardType: keyboardType,
            uchrBase64: layout.uchrData.base64EncodedString())
    }

    /// Returns `nil` when the base64 payload is malformed.
    public func makeLayout() -> KeyboardLayout? {
        guard let data = Data(base64Encoded: uchrBase64) else { return nil }
        return KeyboardLayout(
            sourceID: sourceID,
            localizedName: sourceID,
            languageCode: languageCode,
            uchrData: data)
    }
}
