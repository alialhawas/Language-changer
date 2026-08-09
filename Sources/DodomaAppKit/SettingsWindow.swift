import AppKit
import DodomaCore
import SwiftUI
import UniformTypeIdentifiers

/// One row of the per-app policy table.
///
/// The name and the icon are resolved once, when the settings change, rather
/// than inside `body`: LaunchServices lookups are cached but not free, and a
/// SwiftUI list re-evaluates its rows far more often than the settings change.
struct AppPolicyRow: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: NSImage?
    let policy: AppPolicy

    static func == (lhs: AppPolicyRow, rhs: AppPolicyRow) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name && lhs.policy == rhs.policy
    }
}

/// Main-thread mirror of the settings blob, plus the two things that live
/// outside it: the login-item registration and the resolved app names.
///
/// Every write goes straight to `SettingsStore`, which persists it and calls
/// back through `AppDelegate` into `accept(_:)`. The UI therefore never holds a
/// value the pipeline has not already been given — there is no Apply button and
/// nothing to keep in step.
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var policyRows: [AppPolicyRow] = []
    @Published private(set) var skipRows: [AppPolicyRow] = []
    @Published private(set) var loginStatus: LoginItemStatus = .disabled

    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        settings = store.settings
        rebuildRows()
    }

    // MARK: - Reading

    func refresh() {
        accept(store.settings)
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        let status = LoginItem.status
        if status != loginStatus { loginStatus = status }
    }

    /// The store's change notification. Also the tail of every write below, so
    /// the published value is always the persisted one.
    func accept(_ updated: AppSettings) {
        guard updated != settings else { return }
        settings = updated
        rebuildRows()
    }

    private func rebuildRows() {
        policyRows = settings.appPolicies
            .map { row(bundleID: $0.key, policy: $0.value) }
            .sorted(by: Self.byName)
        skipRows = settings.axVerifySkip
            .map { row(bundleID: $0, policy: settings.policy(for: $0)) }
            .sorted(by: Self.byName)
    }

    private func row(bundleID: String, policy: AppPolicy) -> AppPolicyRow {
        AppPolicyRow(
            bundleID: bundleID,
            name: AppDirectory.displayName(for: bundleID),
            icon: AppDirectory.icon(for: bundleID),
            policy: policy)
    }

    /// Name first, identifier as the tie-break — two uninstalled apps can
    /// resolve to the same name, and a list whose order flickers is unusable.
    private static func byName(_ lhs: AppPolicyRow, _ rhs: AppPolicyRow) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.bundleID < rhs.bundleID
    }

    // MARK: - Writing

    func setAggressiveness(_ level: Aggressiveness) {
        store.setAggressiveness(level)
        accept(store.settings)
    }

    func setPaused(_ paused: Bool) {
        store.setPaused(paused)
        accept(store.settings)
    }

    func setDebugLogging(_ enabled: Bool) {
        store.setDebugLogging(enabled)
        accept(store.settings)
    }

    func setDefaultPolicy(_ policy: AppPolicy) {
        store.setDefaultPolicy(policy)
        accept(store.settings)
    }

    func setPolicy(_ policy: AppPolicy, for bundleID: String) {
        store.setPolicy(policy, for: bundleID)
        accept(store.settings)
    }

    /// Removing a row is not "set it to the default": it deletes the override,
    /// so the app follows `defaultPolicy` from then on, including if that
    /// default later changes.
    func removePolicy(for bundleID: String) {
        store.removePolicy(for: bundleID)
        accept(store.settings)
    }

    func addPolicy(for bundleID: String) {
        guard settings.appPolicies[bundleID] == nil else { return }
        setPolicy(settings.defaultPolicy, for: bundleID)
    }

    func addAXVerifySkip(_ bundleID: String) {
        store.setAXVerifySkip(settings.axVerifySkip.union([bundleID]))
        accept(store.settings)
    }

    func removeAXVerifySkip(_ bundleID: String) {
        store.setAXVerifySkip(settings.axVerifySkip.subtracting([bundleID]))
        accept(store.settings)
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        loginStatus = LoginItem.setEnabled(enabled)
    }

    func openLoginItemSettings() {
        LoginItem.openSettings()
    }
}

/// Lazily created settings window.
///
/// Same shape as `DebugWindowController`: the app has no SwiftUI `App`
/// lifecycle, so this is a plain `NSWindow` hosting a SwiftUI view.
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(settings: SettingsStore) {
        model = SettingsModel(store: settings)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        // `makeKeyAndOrderFront` and not `NSApp.activate`: onboarding is the one
        // place this app is allowed to take the screen away from whatever the
        // user is typing in. Opening the menu already brings Dodoma forward for
        // the duration of the click, which is enough for the window to come up
        // usable.
        window.makeKeyAndOrderFront(nil)
    }

    /// Driven by the app delegate's existing two-second permission poll rather
    /// than by a timer of its own. Approval of a login item happens in System
    /// Settings, so the status has to be re-read from outside.
    func poll() {
        guard isVisible else { return }
        model.refreshLoginStatus()
    }

    func settingsChanged(_ settings: AppSettings) {
        model.accept(settings)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Dodoma Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.setFrameAutosaveName("DodomaSettingsWindow")
        return window
    }
}

// MARK: - Views

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Text("General") }
            ApplicationsTab(model: model)
                .tabItem { Text("Applications") }
            AdvancedTab(model: model)
                .tabItem { Text("Advanced") }
        }
        .padding(16)
        .frame(width: 560, height: 480)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Aggressiveness", selection: aggressiveness) {
                    ForEach(Aggressiveness.allCases, id: \.self) { level in
                        Text(SettingsCopy.title(level)).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(SettingsCopy.explanation(model.settings.aggressiveness))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Section {
                Toggle("Pause Dodoma", isOn: paused)
                Text("Nothing is buffered, evaluated or rewritten while this is on. "
                    + "The same switch as ⌘⌥P and the menu item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Section {
                Toggle("Start Dodoma at login", isOn: loginItem)
                    .disabled(model.loginStatus == .unavailable)
                if !model.loginStatus.explanation.isEmpty {
                    Text(model.loginStatus.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.loginStatus == .requiresApproval {
                    Button("Open Login Items Settings…") { model.openLoginItemSettings() }
                }
            }

            Divider()

            Section {
                Toggle("Debug logging", isOn: debugLogging)
                Text("Logs the text of detected regions to the system log. "
                    + "Leave this off unless you are diagnosing a wrong fix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var aggressiveness: Binding<Aggressiveness> {
        Binding(get: { model.settings.aggressiveness }, set: { model.setAggressiveness($0) })
    }

    private var paused: Binding<Bool> {
        Binding(get: { model.settings.paused }, set: { model.setPaused($0) })
    }

    private var debugLogging: Binding<Bool> {
        Binding(get: { model.settings.debugLogging }, set: { model.setDebugLogging($0) })
    }

    private var loginItem: Binding<Bool> {
        Binding(get: { model.loginStatus.isOn }, set: { model.setLoginItemEnabled($0) })
    }
}

private struct ApplicationsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All other apps")
                    .frame(maxWidth: .infinity, alignment: .leading)
                PolicyPicker(
                    policy: model.settings.defaultPolicy,
                    onChange: { model.setDefaultPolicy($0) })
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            List {
                ForEach(model.policyRows) { row in
                    HStack(spacing: 8) {
                        AppIcon(image: row.icon)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.bundleID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PolicyPicker(
                            policy: row.policy,
                            onChange: { model.setPolicy($0, for: row.bundleID) })
                        Button {
                            model.removePolicy(for: row.bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this override; the app follows the default above.")
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("+ Add app…") { addApp() }
                Spacer()
                Text("Removing a row does not switch Dodoma off for that app — it reverts it "
                    + "to the default above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addApp() {
        guard let bundleID = AppChooser.chooseBundleID(
            prompt: "Choose an application to give its own mode.")
        else { return }
        model.addPolicy(for: bundleID)
    }
}

private struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skip accessibility verification")
                .font(.headline)
            Text("Before deleting anything, Dodoma reads the text in front of the caret and "
                + "checks that it is exactly what it recorded you typing. Apps listed here "
                + "skip that read: the rewrite goes ahead unverified, so a stale buffer "
                + "deletes whatever happens to be in front of the caret instead. The list "
                + "exists for apps where touching the accessibility tree is expensive — "
                + "Chromium force-enables its whole tree the moment anything reads it. Empty "
                + "is the right answer unless you have that specific problem.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.skipRows) { row in
                    HStack(spacing: 8) {
                        AppIcon(image: row.icon)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.bundleID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.removeAXVerifySkip(row.bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 120)

            Button("+ Add app…") { addApp() }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Undo window").foregroundStyle(.secondary)
                    Text(SettingsCopy.undoWindow)
                }
                GridRow {
                    Text("Shortcuts").foregroundStyle(.secondary)
                    Text("\(SettingsCopy.undoChord) / \(SettingsCopy.pauseChord)")
                }
                GridRow {
                    Text("").foregroundStyle(.secondary)
                    Text("undo / pause — rebinding not yet supported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func addApp() {
        guard let bundleID = AppChooser.chooseBundleID(
            prompt: "Choose an application to exempt from caret verification.")
        else { return }
        model.addAXVerifySkip(bundleID)
    }
}

private struct PolicyPicker: View {
    let policy: AppPolicy
    let onChange: (AppPolicy) -> Void

    var body: some View {
        Picker(
            "",
            selection: Binding(get: { policy }, set: { onChange($0) })
        ) {
            ForEach(AppPolicy.allCases, id: \.self) { option in
                Text(SettingsCopy.title(option)).tag(option)
            }
        }
        .labelsHidden()
        .frame(width: 140)
    }
}

private struct AppIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// The open panel behind both "+ Add app…" buttons.
private enum AppChooser {
    /// nil when the user cancels, or when the thing they picked is not an app
    /// bundle — a bundle with no identifier cannot be keyed on, and silently
    /// adding nothing would look like the button was broken.
    static func chooseBundleID(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundleID = AppDirectory.bundleID(atApplicationURL: url) else {
            let alert = NSAlert()
            alert.messageText = "That application has no bundle identifier."
            alert.informativeText =
                "Dodoma keys its settings on the bundle identifier, so \(url.lastPathComponent) "
                + "cannot be added."
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
        return bundleID
    }
}

/// Every user-facing string in the settings window, in one place.
enum SettingsCopy {
    static func title(_ level: Aggressiveness) -> String {
        switch level {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .eager: return "Eager"
        }
    }

    static func explanation(_ level: Aggressiveness) -> String {
        switch level {
        case .conservative:
            return "Rewrites only when the other layout is an overwhelming improvement. "
                + "Misses some real mistakes; almost never touches text it should not."
        case .balanced:
            return "The default. Rewrites clear cases, offers the borderline ones as a "
                + "suggestion card next to the caret."
        case .eager:
            return "Rewrites on a smaller margin and offers more. Catches more mistakes and "
                + "produces more wrong fixes; ⌘⌥Z is the way back from those."
        }
    }

    static func title(_ policy: AppPolicy) -> String {
        switch policy {
        case .normal: return "Normal"
        case .suggestOnly: return "Suggest only"
        case .off: return "Off"
        }
    }

    static var undoWindow: String {
        "\(Int(FixHistory.undoWindow.rounded())) s"
    }

    /// Spelled out rather than derived: a hot key is a key code and a rendered
    /// chord is characters, and nothing translates one into the other without
    /// asking the active layout. `SettingsCopyTests` pins these against
    /// `Hotkeys` so the two cannot drift.
    static let undoChord = "⌘⌥Z"
    static let pauseChord = "⌘⌥P"
}
