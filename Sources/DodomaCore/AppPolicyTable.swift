import Foundation

/// Which apps Dodoma is allowed to rewrite text in.
///
/// PLACEHOLDER FOR M5. The real safety layer replaces this whole type with
/// secure-input detection, an accessibility check of the focused field, the
/// suggest-only terminal list, the never-touch password-manager list and the
/// user's own per-app overrides. Until then the allowlist is exactly one app,
/// so that a bug in the destructive path can only ever damage a scratch
/// TextEdit document.
public enum AppPolicyTable {
    /// M5 REPLACES THIS. Bundle identifiers that may be auto-fixed.
    public static let allowlist: Set<String> = ["com.apple.TextEdit"]

    /// `.normal` for an allowlisted app, `.off` for everything else including
    /// an unknown frontmost app.
    public static func policy(forBundleID bundleID: String?) -> AppPolicy {
        guard let bundleID, allowlist.contains(bundleID) else { return .off }
        return .normal
    }
}
