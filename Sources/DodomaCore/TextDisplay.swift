import Foundation

/// Shortening rules for text shown in the UI.
///
/// Lives in the core, away from the views, because the arithmetic is fiddly
/// enough to be worth testing and none of it needs AppKit.
public enum TextDisplay {
    public static let ellipsis: Character = "…"

    /// Shortens `text` to `limit` characters by dropping the middle.
    ///
    /// Both ends are kept because that is what makes two similar fixes
    /// distinguishable in a menu: a common prefix is exactly the part that
    /// carries no information. The result is never longer than `limit`, the
    /// ellipsis included, and newlines are flattened to spaces so a multi-line
    /// region cannot break the layout. A `limit` below 2 leaves no room for
    /// both an ellipsis and a character, so the text is returned unshortened.
    public static func middleTruncate(_ text: String, limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard limit > 1, flattened.count > limit else { return flattened }
        let kept = limit - 1
        let tail = kept / 2
        let head = kept - tail
        return "\(flattened.prefix(head))\(ellipsis)\(flattened.suffix(tail))"
    }
}
