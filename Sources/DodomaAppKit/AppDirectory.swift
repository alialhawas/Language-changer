import AppKit
import Foundation

/// Turning a bundle identifier into something a person recognises.
///
/// The settings window stores policies by bundle identifier — that is the only
/// stable key — but `com.googlecode.iterm2` is not a name anybody chose. The
/// lookup goes through LaunchServices, which can fail in three ordinary ways:
/// the app is not installed on this machine (a policy the user set on another
/// machine, or an app since deleted), its `Info.plist` carries no name, or
/// LaunchServices has simply not seen it. Each has its own fallback, and the
/// last one is always the raw identifier — never an empty row.
enum AppDirectory {
    /// The fallback chain, with no AppKit in it so it can be tested directly.
    ///
    /// 1. `CFBundleDisplayName` / `CFBundleName`, which is what the Finder and
    ///    the menu bar show.
    /// 2. The bundle's own file name without `.app`, for bundles whose plist
    ///    has neither key.
    /// 3. The bundle identifier itself.
    static func displayName(bundleID: String, bundleName: String?, bundleURL: URL?) -> String {
        if let bundleName, !bundleName.isEmpty { return bundleName }
        if let bundleURL {
            let fileName = bundleURL.deletingPathExtension().lastPathComponent
            if !fileName.isEmpty { return fileName }
        }
        return bundleID
    }

    /// The same chain, resolved against the running system.
    static func displayName(for bundleID: String) -> String {
        let url = self.url(for: bundleID)
        return displayName(bundleID: bundleID, bundleName: name(at: url), bundleURL: url)
    }

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// The Finder icon, or nil when the app is not installed here.
    ///
    /// `NSWorkspace.icon(forFile:)` is a cached LaunchServices lookup, so it is
    /// cheap enough for a table — but it is called once per row per redraw, so
    /// `SettingsModel` keeps the result rather than asking again.
    static func icon(for bundleID: String) -> NSImage? {
        guard let url = url(for: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The identifier of an application bundle the user picked in an open
    /// panel. nil when the selection is not an app bundle at all.
    static func bundleID(atApplicationURL url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    private static func name(at url: URL?) -> String? {
        guard let url, let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary
        let display = info?["CFBundleDisplayName"] as? String
        let name = info?["CFBundleName"] as? String
        return (display?.isEmpty == false ? display : nil) ?? (name?.isEmpty == false ? name : nil)
    }
}
