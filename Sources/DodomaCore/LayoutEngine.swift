import Carbon.HIToolbox
import Foundation

/// Enumerates the keyboard layouts the user has enabled and caches the result.
///
/// The enabled-sources list only changes when the user edits it in System
/// Settings, and enumeration copies every `uchr` table, so the list is cached
/// until `invalidate()` is called. The app layer drives invalidation from the
/// `kTISNotifyEnabledKeyboardInputSourcesChanged` distributed notification.
public final class LayoutEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedLayouts: [KeyboardLayout]?

    public init() {}

    /// Enabled layouts, from cache when warm.
    public func layouts() -> [KeyboardLayout] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedLayouts { return cachedLayouts }
        let fresh = Self.enabledKeyboardLayouts()
        cachedLayouts = fresh
        return fresh
    }

    /// Drops the cache; the next `layouts()` call re-enumerates.
    public func invalidate() {
        lock.lock()
        cachedLayouts = nil
        lock.unlock()
    }

    /// The English/Arabic pair Dodoma arbitrates between, or `nil` when the
    /// user has not enabled one of them. Warms the cache when cold.
    public func currentPair() -> (english: KeyboardLayout, arabic: KeyboardLayout)? {
        Self.pair(in: layouts())
    }

    /// The English/Arabic pair from the cache *only when it is warm*.
    ///
    /// Returns `nil` when the cache is cold and never calls
    /// `TISCreateInputSourceList`, so it is safe to call off the main thread —
    /// unlike `currentPair()`, which repopulates. A caller on a background
    /// queue that gets `nil` should skip rather than force an off-main
    /// enumeration: `invalidate()` is always followed by a main-thread
    /// `warmLayoutCache()`, so the cache is warm again by the next quiet period.
    /// (Also `nil` when the cache is warm but no English/Arabic pair is
    /// enabled; a cold cache is the only case that would otherwise enumerate.)
    public func cachedPair() -> (english: KeyboardLayout, arabic: KeyboardLayout)? {
        lock.lock()
        let cached = cachedLayouts
        lock.unlock()
        guard let cached else { return nil }
        return Self.pair(in: cached)
    }

    private static func pair(in all: [KeyboardLayout])
        -> (english: KeyboardLayout, arabic: KeyboardLayout)?
    {
        guard
            let english = all.first(where: { $0.languageCode.hasPrefix("en") }),
            let arabic = all.first(where: { $0.languageCode.hasPrefix("ar") })
        else { return nil }
        return (english, arabic)
    }

    /// Every enabled, selectable keyboard input source that carries a `uchr`
    /// table. Sources without one (e.g. input methods) cannot be rendered
    /// through `UCKeyTranslate` and are skipped.
    public static func enabledKeyboardLayouts() -> [KeyboardLayout] {
        let filter =
            [
                kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
            ] as CFDictionary
        guard
            let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as NSArray?
                as? [TISInputSource]
        else { return [] }

        return sources.compactMap(makeLayout(from:))
    }

    /// Input source ID of the layout the user is currently typing in.
    public static func selectedLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return stringProperty(source, kTISPropertyInputSourceID)
    }

    private static func makeLayout(from source: TISInputSource) -> KeyboardLayout? {
        guard
            boolProperty(source, kTISPropertyInputSourceIsEnabled),
            boolProperty(source, kTISPropertyInputSourceIsSelectCapable),
            let sourceID = stringProperty(source, kTISPropertyInputSourceID),
            let uchrData = uchrProperty(source)
        else { return nil }

        return KeyboardLayout(
            sourceID: sourceID,
            localizedName: stringProperty(source, kTISPropertyLocalizedName) ?? sourceID,
            languageCode: languagesProperty(source).first ?? "",
            uchrData: uchrData)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private static func languagesProperty(_ source: TISInputSource) -> [String] {
        guard
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return (array as NSArray as? [String]) ?? []
    }

    /// Copies the `uchr` bytes: the property is returned unretained and is only
    /// guaranteed to live as long as the input source.
    private static func uchrProperty(_ source: TISInputSource) -> Data? {
        guard
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        let length = CFDataGetLength(cfData)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        CFDataGetBytes(cfData, CFRangeMake(0, length), &bytes)
        return Data(bytes)
    }
}
