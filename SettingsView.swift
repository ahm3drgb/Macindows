import SwiftUI
import ServiceManagement

/// Every user-facing switch lives in UserDefaults under these keys.
/// AppDelegate reads them through `Settings`, the window writes them through @AppStorage.
enum Settings {
    static let menuBarShowDesktop  = "MenuBarClickShowsDesktop"
    static let dockClickMinimize   = "DockClickMinimize"
    static let titleBarDoubleClick = "TitleBarDoubleClickFill"
    static let hoverPreview        = "HoverPreview"
    static let previewDelay        = "HoverPreviewDelay"
    static let previewHideDelay    = "HoverPreviewHideDelay"
    static let restoreOnActivate   = "RestoreMinimizedOnActivate"
    static let rawScroll           = "RawScrollEnabled"
    static let scrollLines         = "ScrollLinesPerNotch"
    static let mouseSpeed          = "MouseSpeedMultiplier"
    static let finderZoom          = "FinderCtrlScrollZoom"
    static let finderBackspaceBack = "FinderBackspaceBack"
    static let finderEnterOpens    = "FinderEnterOpens"
    static let cmdShiftLanguage    = "CmdShiftSwitchesLanguage"
    static let lockedAppsKey       = "LockedAppBundleIDs"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarShowDesktop: true,
            dockClickMinimize: true,
            titleBarDoubleClick: true,
            hoverPreview: true,
            previewDelay: 0.1,
            previewHideDelay: 0.1,
            restoreOnActivate: true,
            rawScroll: true,
            scrollLines: 3,
            mouseSpeed: 1.0,
            finderZoom: true,
            finderBackspaceBack: true,
            finderEnterOpens: true,
            cmdShiftLanguage: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
    /// Bundle IDs that need Touch ID before they show.
    static var lockedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: lockedAppsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: lockedAppsKey) }
    }
}

struct SettingsView: View {
    @AppStorage(Settings.menuBarShowDesktop)  private var menuBarShowDesktop = true
    @AppStorage(Settings.dockClickMinimize)   private var dockClickMinimize = true
    @AppStorage(Settings.titleBarDoubleClick) private var titleBarDoubleClick = true
    @AppStorage(Settings.hoverPreview)        private var hoverPreview = true
    @AppStorage(Settings.previewDelay)        private var previewDelay = 0.1
    @AppStorage(Settings.previewHideDelay)    private var previewHideDelay = 0.1
    @AppStorage(Settings.restoreOnActivate)   private var restoreOnActivate = true
    @AppStorage(Settings.rawScroll)           private var rawScroll = true
    @AppStorage(Settings.scrollLines)         private var scrollLines = 3
    @AppStorage(Settings.mouseSpeed)          private var mouseSpeed = 1.0
    @AppStorage(Settings.finderZoom)          private var finderZoom = true
    @AppStorage(Settings.finderBackspaceBack) private var finderBackspaceBack = true
    @AppStorage(Settings.finderEnterOpens)    private var finderEnterOpens = true
    @AppStorage(Settings.cmdShiftLanguage)    private var cmdShiftLanguage = true
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var lockedApps = Settings.lockedApps

    enum Pane: String, CaseIterable, Identifiable {
        case dock = "Dock", finder = "Finder", mouse = "Mouse", keyboard = "Keyboard", appLock = "App Lock", general = "General"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dock: return "dock.rectangle"
            case .finder: return "folder"
            case .mouse: return "computermouse"
            case .keyboard: return "keyboard"
            case .appLock: return "lock"
            case .general: return "gearshape"
            }
        }
    }
    @State private var pane: Pane = .dock

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases) { p in
                    Button {
                        pane = p
                    } label: {
                        Label(p.rawValue, systemImage: p.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7).padding(.horizontal, 10)
                            .background(pane == p ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)
            .background(.ultraThinMaterial)

            Divider()

            // Content
            Group {
                switch pane {
                case .dock: dockTab
                case .finder: finderTab
                case .mouse: mouseTab
                case .keyboard: keyboardTab
                case .appLock: appLockTab
                case .general: generalTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 560)
    }

    private var dockTab: some View {
        Form {
            Section {
                Toggle(isOn: $menuBarShowDesktop) {
                    label("Menu bar icon click shows desktop", "menubar.dock.rectangle",
                          "Left-click hides every app; click again to bring them back. Right-click always opens this menu.")
                }
                Toggle(isOn: $dockClickMinimize) {
                    label("Click Dock icon to minimize", "dock.arrow.down.rectangle",
                          "Clicking the icon of the front app minimizes its windows, like the Windows taskbar.")
                }
                Toggle(isOn: $restoreOnActivate) {
                    label("Restore minimized window on ⌘ Tab", "rectangle.on.rectangle",
                          "Switching to an app with only minimized windows brings one back.")
                }
                Toggle(isOn: $titleBarDoubleClick) {
                    label("Double-click title bar to fill screen", "arrow.up.left.and.arrow.down.right",
                          "Toggles between filled and the previous size.")
                }
            } header: { Text("Windows") }

            Section {
                Toggle(isOn: $hoverPreview) {
                    label("Show window thumbnails on hover", "photo.on.rectangle",
                          "Hover a Dock icon to see and manage its windows.")
                }
                if hoverPreview {
                    slider("Show after", value: $previewDelay, in: 0.1...1.0, step: 0.1,
                           format: { String(format: "%.1f s", $0) })
                    slider("Hide after leaving", value: $previewHideDelay, in: 0.1...2.0, step: 0.1,
                           format: { String(format: "%.1f s", $0) })
                }
            } header: { Text("Thumbnails") }

        }
        .formStyle(.grouped)
    }

    private var finderTab: some View {
        Form {
            Section {
                Toggle(isOn: $finderZoom) {
                    label("⌃ Control + scroll resizes icons", "square.grid.3x3.square",
                          "In icon view, hold Control and scroll to zoom icons, like Windows.")
                }
                Text("Live resizing uses Finder's status bar slider: in Finder choose View › Show Status Bar (⌘/). Without it, Finder redraws with a short flicker.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Icon view") }

            Section {
                Toggle(isOn: $finderEnterOpens) {
                    label("Enter opens, F2 renames", "return",
                          "Windows keys. While renaming, Enter confirms the name as usual.")
                }
                if finderEnterOpens {
                    Text("On Mac keyboards F2 is a brightness key: press **fn + F2**, or turn on System Settings › Keyboard › \"Use F1, F2, etc. keys as standard function keys\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $finderBackspaceBack) {
                    label("Backspace goes back", "arrow.uturn.backward",
                          "Like Windows Explorer. While typing in a field, Backspace deletes as usual.")
                }
            } header: { Text("Keyboard") }
        }
        .formStyle(.grouped)
    }

    private var mouseTab: some View {
        Form {
            Section {
                Toggle(isOn: $rawScroll) {
                    label("Raw scroll (1:1, no acceleration)", "scroll",
                          "Each mouse-wheel notch scrolls a fixed number of lines. Trackpad is untouched.")
                }
                if rawScroll {
                    slider("Lines per notch", value: Binding(
                        get: { Double(scrollLines) }, set: { scrollLines = Int($0) }),
                        in: 1...20, step: 1, format: { String(format: "%.0f", $0) })
                }
            } header: { Text("Scrolling") }

            Section {
                slider("Speed multiplier", value: $mouseSpeed, in: 1.0...2.0, step: 0.1,
                       format: { String(format: "%.1f×", $0) })
                Text("Goes beyond the system maximum. 1.0× leaves the system setting alone.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Pointer") }
        }
        .formStyle(.grouped)
    }

    private var keyboardTab: some View {
        Form {
            Section {
                Toggle(isOn: $cmdShiftLanguage) {
                    label("⌘ + ⇧ switches input language", "globe",
                          "Press and release Command + Shift together, like Alt + Shift on Windows. Shortcuts such as ⌘⇧S keep working.")
                }
                Text("Cycles through the layouts enabled in System Settings › Keyboard › Input Sources.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Input language") }
        }
        .formStyle(.grouped)
    }

    private var appLockTab: some View {
        Form {
            Section {
                ForEach(lockedApps, id: \.self) { id in
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    HStack {
                        if let url = url {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 24, height: 24)
                        }
                        Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                        Spacer()
                        Button(role: .destructive) {
                            lockedApps.removeAll { $0 == id }
                            Settings.lockedApps = lockedApps
                        } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add App…", action: addLockedApps)
            } header: { Text("Locked apps") } footer: {
                Text("A locked app hides until you pass Touch ID (or your login password). It locks again when it quits, closes its last window, the screen locks or the Mac sleeps. Press ⌃⌘L to lock them all now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addLockedApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Lock"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !lockedApps.contains(id) else { continue }
            lockedApps.append(id)
        }
        Settings.lockedApps = lockedApps
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(isOn: $startAtLogin) {
                    label("Start at login", "power", nil)
                }
                .onChange(of: startAtLogin) { _, on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }
            }
            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                }
                LabeledContent("Permissions") {
                    Button(Permission.allGranted ? "All granted" : "Fix…") { PermissionsWindowController.shared.show() }
                }
            } header: { Text("About") }
        }
        .formStyle(.grouped)
    }

    private func label(_ title: String, _ symbol: String, _ subtitle: String?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle = subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double, format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

/// Owns the single settings window.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Macindows Settings"
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Permissions onboarding

enum Permission: CaseIterable {
    case accessibility, inputMonitoring, screenRecording

    var title: String {
        switch self {
        case .accessibility:   return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }
    var why: String {
        switch self {
        case .accessibility:   return "Detect Dock clicks, minimize and restore windows."
        case .inputMonitoring: return "Raw scroll and mouse speed."
        case .screenRecording: return "Window thumbnails in the Dock preview."
        }
    }
    var symbol: String {
        switch self {
        case .accessibility:   return "figure.wave"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }
    var granted: Bool {
        switch self {
        case .accessibility:   return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }
    /// Triggers the system prompt (adds the app to the list) and opens the pane.
    func request() {
        switch self {
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        case .inputMonitoring: CGRequestListenEventAccess()
        case .screenRecording: CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(URL(string: settingsURL)!)
    }
    private var settingsURL: String {
        let base = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        switch self {
        case .accessibility:   return base + "Accessibility"
        case .inputMonitoring: return base + "ListenEvent"
        case .screenRecording: return base + "ScreenCapture"
        }
    }
    static var allGranted: Bool { allCases.allSatisfy { $0.granted } }
}

struct PermissionsView: View {
    @State private var status = Permission.allCases.map { $0.granted }
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Macindows needs three permissions").font(.title2.bold())
            Text("macOS asks for each one separately. Click a button, turn on Macindows in the list, then come back.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(spacing: 10) {
                ForEach(Array(Permission.allCases.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 12) {
                        Image(systemName: p.symbol).font(.title2).frame(width: 28).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.headline)
                            Text(p.why).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if status[i] {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).labelStyle(.titleAndIcon)
                        } else {
                            Button("Grant…") { p.request() }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            if status.allSatisfy({ $0 }) {
                Text("All set. Relaunch so every feature picks the permissions up.")
                    .font(.callout)
                Button("Relaunch Macindows") { relaunch() }.buttonStyle(.borderedProminent)
            } else {
                Text("Screen Recording only takes effect after a relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Relaunch Macindows") { relaunch() }
            }
        }
        .padding(28)
        .frame(width: 520)
        .onReceive(timer) { _ in status = Permission.allCases.map { $0.granted } }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

final class PermissionsWindowController {
    static let shared = PermissionsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Welcome to Macindows"
            w.contentViewController = NSHostingController(rootView: PermissionsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
