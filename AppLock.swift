// Copyright (c) 2026 Ahmed Abokhalil. All rights reserved.

import Cocoa
import SwiftUI
import LocalAuthentication
import Carbon

/// Hides apps in the locked list until the user passes Touch ID (or the login password).
/// An app stays unlocked until it quits, closes its last window, the screen locks, the Mac sleeps
/// or the user presses ⌃⌘L.
final class AppLock {
    static let shared = AppLock()

    private var unlocked = Set<pid_t>()
    private var authenticating = Set<pid_t>()
    /// Unlocked apps seen without windows on the previous tick
    private var windowless = Set<pid_t>()
    private var hotKey: EventHotKeyRef?
    /// Full-screen covers shown while a prompt is up. Hiding alone is not enough:
    /// a second Dock click reopens the app's window right after we hide it.
    private var shields: [NSPanel] = []

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.guardApp(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unlocked.remove(app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lockAll()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.lockAll()
        }
        // ⌃⌘L locks every locked app at once. Carbon hot keys need no permission and swallow the key.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            AppLock.shared.lockAll()
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | controlKey),
                            EventHotKeyID(signature: OSType(0x4D4C434B), id: 1), // 'MLCK'
                            GetApplicationEventTarget(), 0, &hotKey)
        // Closing the window keeps the app running (red button, not ⌘Q): lock it again
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.enforce() }
        // Locked apps already running when Macindows starts: hide them now
        NSWorkspace.shared.runningApplications.filter(isLocked).forEach { $0.hide() }
    }

    /// True while the app's windows must not be shown (also keeps them out of Dock thumbnails).
    func isLocked(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, Settings.lockedApps.contains(id) else { return false }
        return !unlocked.contains(app.processIdentifier)
    }

    func lockAll() {
        unlocked.removeAll()
        NSWorkspace.shared.runningApplications.filter(isLocked).forEach { $0.hide() }
    }

    /// Runs every second:
    /// - hides a locked app that shows windows without activating (Show All, desktop restore)
    /// - locks an unlocked app once it has had no on-screen window for two ticks in a row;
    ///   two ticks give unhide and new windows time to appear.
    private func enforce() {
        guard !Settings.lockedApps.isEmpty else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let withWindows = Set(list.compactMap { info -> pid_t? in
            guard info[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return info[kCGWindowOwnerPID as String] as? pid_t
        })
        for pid in withWindows {
            if let app = NSRunningApplication(processIdentifier: pid), isLocked(app) { app.hide() }
        }
        for pid in unlocked where !withWindows.contains(pid) {
            if windowless.insert(pid).inserted { continue }
            unlocked.remove(pid)
            windowless.remove(pid)
            // Hidden means inactive, so the next Dock click activates it and asks again
            NSRunningApplication(processIdentifier: pid)?.hide()
        }
        windowless.formIntersection(unlocked.subtracting(withWindows))
    }

    private func guardApp(_ app: NSRunningApplication) {
        guard isLocked(app) else { return }
        // Hide on every activation, even while the prompt is up, so nothing shows behind it
        app.hide()
        let pid = app.processIdentifier
        guard !authenticating.contains(pid) else { return }
        authenticating.insert(pid)
        showShield(for: app)

        let context = LAContext()
        let reason = "unlock \(app.localizedName ?? "this app")"
        NSApp.activate(ignoringOtherApps: true)
        // .deviceOwnerAuthentication = Touch ID, falling back to the login password
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                self.authenticating.remove(pid)
                if self.authenticating.isEmpty { self.hideShield() }
                guard success, !app.isTerminated else { return }
                self.unlocked.insert(pid)
                self.windowless.remove(pid)
                app.unhide()
                app.activate()
            }
        }
    }

    private func showShield(for app: NSRunningApplication) {
        guard shields.isEmpty else { return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            // Above app windows, below the Dock, menu bar and the Touch ID prompt
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: ShieldView(icon: app.icon, name: app.localizedName ?? "App"))
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            shields.append(panel)
        }
    }

    private func hideShield() {
        shields.forEach { $0.orderOut(nil) }
        shields = []
    }
}

private struct ShieldView: View {
    let icon: NSImage?
    let name: String

    var body: some View {
        VStack(spacing: 14) {
            if let icon = icon {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            Label("\(name) is locked", systemImage: "lock.fill").font(.title2.bold())
            Text("Use Touch ID or your password to unlock.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
