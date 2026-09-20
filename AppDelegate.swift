import Cocoa
import ServiceManagement
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Carbon


class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitors: [Any] = []
    private var frontmostOnDown: NSRunningApplication?
    private var activationDuringClick = false
    private var clickedAppOnDown: NSRunningApplication?
    private var dockWindowCountOnDown = 0
    private var statusItem: NSStatusItem!
    private var lastMinimizedApp: NSRunningApplication?
    private var lastMinimizeAt: Date?
    private var mouseDownPoint: NSPoint = .zero
    private var preFillFrame: CGRect?
    private var preFillPID: pid_t = 0
    private var hiddenApps: [NSRunningApplication] = []
    private var isDesktopShown = false
    private var desktopToggleBusy = false
    private var previewPanel: WindowPreviewPanel?
    private var hoverTimer: Timer?
    private var dismissTimer: Timer?
    private var hoveredApp: NSRunningApplication?

    // MARK: - Raw Scroll (1:1 Windows-like)
    private var scrollEventTap: CFMachPort?
    private var scrollRunLoopSource: CFRunLoopSource?
    private var rawScrollEnabled: Bool = false {
        didSet { syncScrollTap() }
    }
    private func syncScrollTap() {
        if let tap = scrollEventTap {
            CGEvent.tapEnable(tap: tap, enable: rawScrollEnabled || Settings.bool(Settings.finderZoom))
        }
    }
    /// Lines per scroll notch — 3 matches Windows default
    private static var scrollLinesPerNotch: Int64 = 3

    // MARK: - Finder keyboard (Backspace = Back)
    private var keyTap: CFMachPort?
    private var keyRunLoopSource: CFRunLoopSource?
    private var finderIsFront = false
    private var finderRenaming = false
    /// ⌘⇧ chord: armed when both are held with nothing else, disarmed by any other key
    private var cmdShiftArmed = false
    private lazy var finderAX: AXUIElement? = {
        guard let f = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return nil }
        let ax = AXUIElementCreateApplication(f.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.05)
        return ax
    }()

    // MARK: - Mouse Speed Multiplier
    private var mouseSpeedTap: CFMachPort?
    private var mouseSpeedRunLoopSource: CFRunLoopSource?
    private static var mouseSpeedMultiplier: Double = 1.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Settings.registerDefaults()
        applySettings()
        setupMenuBar()
        setupLoginItem()
        setupMacindows()
        setupRawScrollTap()
        setupMouseSpeedTap()
        setupFinderKeyTap()
        // The settings window writes UserDefaults; pick every change up live
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(restoreMinimizedOnActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidDeactivate(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil
        )

        // First run / missing grants: guide the user instead of failing silently
        if !Permission.allGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { PermissionsWindowController.shared.show() }
        }

        // Keep thumbnails of the active app fresh so a window minimized with the
        // yellow button still previews (macOS cannot capture minimized windows).
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard self?.previewPanel == nil,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            WindowThumbnailer.snapshotOnScreenWindows(of: app)
        }


    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Macindows")
        button.action = #selector(statusBarClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    @objc private func statusBarClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || !Settings.bool(Settings.menuBarShowDesktop) {
            showDropdownMenu()
        } else {
            toggleDesktop()
        }
    }

    private func toggleDesktop() {
        guard !desktopToggleBusy else { return }
        desktopToggleBusy = true
        if isDesktopShown {
            hiddenApps.forEach { _ = $0.unhide() }
            hiddenApps = []
            isDesktopShown = false
            statusItem.button?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Macindows")
        } else {
            hiddenApps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isHidden && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            hiddenApps.forEach { _ = $0.hide() }
            isDesktopShown = true
            statusItem.button?.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "Macindows")
        }
        // Let the system's hide/unhide animation play out before accepting another toggle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.desktopToggleBusy = false
        }
    }

    private func showDropdownMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Macindows", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func settingsChanged() { applySettings() }

    /// Push UserDefaults into the live state (taps, static values, open preview).
    private func applySettings() {
        rawScrollEnabled = Settings.bool(Settings.rawScroll)
        syncScrollTap()
        AppDelegate.scrollLinesPerNotch = Int64(max(1, Settings.int(Settings.scrollLines)))
        let speed = Settings.double(Settings.mouseSpeed)
        AppDelegate.mouseSpeedMultiplier = speed > 0 ? speed : 1.0
        if let tap = mouseSpeedTap { CGEvent.tapEnable(tap: tap, enable: AppDelegate.mouseSpeedMultiplier > 1.001) }
        if !Settings.bool(Settings.hoverPreview) { dismissWindowPreview(animated: false) }
        if let tap = keyTap {
            CGEvent.tapEnable(tap: tap, enable: keyTapWanted)
        }
    }

    // MARK: - Dock Icon Click Toggle

    private func setupMacindows() {
        // Always use NSEvent.mouseLocation: e.locationInWindow on global events is not
        // reliably in screen coordinates (macOS 26+ sometimes reports it relative to
        // another app's window), which made the preview dismiss as the cursor reached it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            let pt = NSEvent.mouseLocation
            // Clicking a Dock icon: preview out of the way, the click itself toggles minimize
            if let self = self, self.isDockArea(pt) {
                self.hoverTimer?.invalidate()
                self.dismissWindowPreview(animated: false)
                self.suppressPreviewUntil = Date().addingTimeInterval(0.6)
            }
            self?.handleDown(pt)
            if e.clickCount == 2 { self?.handleDoubleClick(at: pt) }
        }) { monitors.append(m) }

        // Right-click on the Dock opens the Dock's own menu: hide our preview, stay out of the way
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
            guard let self = self, self.isDockArea(NSEvent.mouseLocation) else { return }
            self.hoverTimer?.invalidate()
            self.dismissWindowPreview(animated: false)
            self.suppressPreviewUntil = Date().addingTimeInterval(0.6)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.handleUp(NSEvent.mouseLocation)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.handleMouseMoved(NSEvent.mouseLocation)
        }) { monitors.append(m) }

        // Local monitor to track mouse when it's over our own preview panel
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in
            self?.handleMouseMoved(NSEvent.mouseLocation)
            return e
        }) { monitors.append(m) }
    }

    @objc private func appDidActivate() {
        if frontmostOnDown != nil { activationDuringClick = true }
        finderIsFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        finderRenaming = false
    }

    @objc private func appDidDeactivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        WindowThumbnailer.snapshotOnScreenWindows(of: app)
    }

    // MARK: - Windows-style switching: activating an app restores a minimized window

    /// Cmd+Tab (and other activations) on macOS leave minimized windows minimized.
    /// Windows restores one. Wait briefly so macOS's own restore (dock click,
    /// preview-panel select) can land first, then restore only if nothing is visible.
    /// Set when we activate an app ourselves (preview click) so the auto-restore stays out of the way.
    private var suppressAutoRestoreUntil = Date.distantPast

    @objc private func restoreMinimizedOnActivate(_ note: Notification) {
        guard Settings.bool(Settings.restoreOnActivate),
              Date() > suppressAutoRestoreUntil,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        // Check twice: AX/CG state can lag right after activation
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard app.isActive, !self.hasOnScreenWindows(app) else { return }
                self.unminimizeFirstWindow(of: app)
            }
        }
    }

    /// True if the app has at least one real window on screen (layer 0, non-trivial size).
    /// Ignores hidden helper windows that AX still reports as non-minimized.
    private func hasOnScreenWindows(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = b["Width"], let h = b["Height"] else { return false }
            return w > 50 && h > 50
        }
    }

    private func unminimizeFirstWindow(of app: NSRunningApplication) {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        for w in windows {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(w, "AXMinimized" as CFString, &v)
            if (v as? Bool) == true {
                AXUIElementSetAttributeValue(w, "AXMinimized" as CFString, false as CFTypeRef)
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                return
            }
        }
    }

    private func handleDown(_ pt: NSPoint) {
        activationDuringClick = false
        mouseDownPoint = pt
        guard isDockArea(pt) else { frontmostOnDown = nil; clickedAppOnDown = nil; return }
        let app = NSWorkspace.shared.frontmostApplication
        // Don't re-minimize if we just minimized this app — user is clicking to restore
        let recentlyMinimized = lastMinimizedApp == app
            && (lastMinimizeAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false)
        if recentlyMinimized {
            // This click is the restore — clear so the next click can minimize again
            lastMinimizedApp = nil
            lastMinimizeAt = nil
        }
        // Only act if the app actually has visible windows — if already minimized, let macOS restore naturally
        frontmostOnDown = (app != nil && !recentlyMinimized && hasVisibleWindows(app!)) ? app : nil
        clickedAppOnDown = axAppAtDockIcon(pt)
        dockWindowCountOnDown = dockAXWindowCount()
    }

    private func handleUp(_ pt: NSPoint) {
        defer { frontmostOnDown = nil; clickedAppOnDown = nil; activationDuringClick = false }
        guard Settings.bool(Settings.dockClickMinimize) else { return }
        let dx = pt.x - mouseDownPoint.x
        let dy = pt.y - mouseDownPoint.y
        let movedTooFar = (dx * dx + dy * dy) > 100  // >10px = drag, not click
        guard !movedTooFar,
              isDockArea(pt),
              !activationDuringClick,
              let appBefore = frontmostOnDown,
              appBefore == NSWorkspace.shared.frontmostApplication,
              appBefore.activationPolicy == .regular,
              appBefore.bundleIdentifier != "com.apple.dock" else { return }

        // Only minimize if we positively confirmed the user clicked the SAME app's
        // dock icon. If clickedAppOnDown is nil (non-running app being launched,
        // or AX couldn't identify the icon) or a different app, do NOT minimize.
        guard let clickedApp = clickedAppOnDown, clickedApp == appBefore else { return }

        let target = appBefore
        let windowsBefore = dockWindowCountOnDown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // If Dock gained windows or became frontmost, a system overlay (App Library, Launchpad) opened
            let dockWins = self.dockAXWindowCount()
            guard dockWins <= windowsBefore,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.dock",
                  target == NSWorkspace.shared.frontmostApplication else { return }
            self.minimizeWindows(of: target)
            self.lastMinimizedApp = target
            self.lastMinimizeAt = Date()
        }
    }

    // MARK: - Double-Click Fill / Restore

    private func handleDoubleClick(at clickPt: NSPoint) {
        guard Settings.bool(Settings.titleBarDoubleClick),
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let pid = app.processIdentifier
        let appAX = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let w = winRef else { return }
        let window = w as! AXUIElement
        guard let preFrame = axGetFrame(window),
              let visibleAX = visibleFrameInAXCoords(for: screen(at: clickPt)) else { return }

        // Only react if the click is within the window's title-bar strip (top ~30px)
        let clickQY = primaryHeight - clickPt.y
        let inTitleBar = clickPt.x >= preFrame.minX && clickPt.x <= preFrame.maxX
            && clickQY >= preFrame.minY && clickQY <= preFrame.minY + 32
        guard inTitleBar else { return }

        let preWasFilled = isApprox(preFrame, visibleAX)

        // Wait long enough for macOS's own title-bar action (if any) to complete, then react
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let nowFrame = self.axGetFrame(window) else { return }
            let nowFilled = self.isApprox(nowFrame, visibleAX)

            if !preWasFilled && nowFilled {
                // macOS filled it — remember the pre-fill frame for the next toggle
                self.preFillFrame = preFrame
                self.preFillPID = pid
            } else if preWasFilled && nowFilled {
                // macOS didn't toggle (Fill setting) — restore from stored pre-fill
                if self.preFillPID == pid, let prev = self.preFillFrame {
                    self.axSetFrame(window, prev)
                }
                self.preFillFrame = nil
                self.preFillPID = 0
            } else if !preWasFilled && !nowFilled {
                // macOS did nothing — we fill it ourselves
                self.preFillFrame = preFrame
                self.preFillPID = pid
                self.axSetFrame(window, visibleAX)
            } else {
                // preWasFilled && !nowFilled: macOS toggled back (Zoom setting) — clear state
                self.preFillFrame = nil
                self.preFillPID = 0
            }
        }
    }

    private func axGetFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private func axSetFrame(_ window: AXUIElement, _ rect: CGRect) {
        var pt = rect.origin
        var sz = rect.size
        if let posVal = AXValueCreate(.cgPoint, &pt) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    private func visibleFrameInAXCoords(for screen: NSScreen?) -> CGRect? {
        guard let screen = screen else { return nil }
        let vis = screen.visibleFrame
        return CGRect(x: vis.minX, y: primaryHeight - vis.maxY, width: vis.width, height: vis.height)
    }

    private func isApprox(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 5) -> Bool {
        return abs(a.minX - b.minX) < tolerance &&
               abs(a.minY - b.minY) < tolerance &&
               abs(a.width - b.width) < tolerance &&
               abs(a.height - b.height) < tolerance
    }

    // MARK: - Window Preview on Hover

    private func handleMouseMoved(_ pt: NSPoint) {
        guard Settings.bool(Settings.hoverPreview) else { return }
        if let panel = previewPanel, panel.isVisible {
            panel.updateHover(screenPoint: pt)
            // Keep panel alive if mouse is inside panel (with generous margin)
            // or anywhere in the dock area, or in the bridge zone between dock and panel
            let panelZone = panel.frame.insetBy(dx: -40, dy: -40)
            if panelZone.contains(pt) || isDockArea(pt) {
                dismissTimer?.invalidate()
                dismissTimer = nil

                // If in dock area and hovering a DIFFERENT app's icon, switch preview
                if isDockArea(pt) {
                    let app = axAppAtDockIcon(pt)
                    if let app = app, app.activationPolicy == .regular {
                        if app != hoveredApp {
                            hoveredApp = app
                            hoverTimer?.invalidate()
                            // Keep the current panel up until the new one is ready
                            hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
                                self?.showPreviewIfStillHovering(app)
                            }
                        }
                    } else if !panelZone.contains(pt) {
                        // Folder, Trash, separator, empty Dock: nothing to preview
                        startDismissTimer()
                    }
                }
                return
            }

            // Mouse is outside both panel and dock — short grace period so a fast
            // move toward the panel doesn't kill it
            startDismissTimer()
            return
        }

        // No panel visible — standard hover detection
        if isDockArea(pt) {
            dismissTimer?.invalidate()
            dismissTimer = nil

            let app = axAppAtDockIcon(pt)
            if let app = app, app.activationPolicy == .regular {
                if app != hoveredApp {
                    hoveredApp = app
                    hoverTimer?.invalidate()
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
                        self?.showPreviewIfStillHovering(app)
                    }
                }
            } else {
                hoveredApp = nil
                hoverTimer?.invalidate()
            }
        } else {
            hoveredApp = nil
            hoverTimer?.invalidate()
        }
    }

    private var lastDismissAt = Date.distantPast
    /// Quick re-show right after an action, normal delay otherwise
    private var hoverDelay: TimeInterval {
        Date().timeIntervalSince(lastDismissAt) < 3 ? 0.1 : max(0.1, Settings.double(Settings.previewDelay))
    }

    private var suppressPreviewUntil = Date.distantPast

    /// True while the Dock has a context menu open (a Dock-owned window at menu level).
    private func dockMenuIsOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "Dock"
                && (($0[kCGWindowLayer as String] as? Int) ?? 0) >= 100
        }
    }

    /// Timer callback: only show if the cursor is still on that app's Dock icon.
    private func showPreviewIfStillHovering(_ app: NSRunningApplication) {
        let now = NSEvent.mouseLocation
        guard Date() > suppressPreviewUntil, !dockMenuIsOpen(),
              isDockArea(now), axAppAtDockIcon(now) == app else { return }
        showWindowPreview(for: app, at: now)
    }

    private func startDismissTimer() {
        guard dismissTimer == nil else { return }
        let delay = max(0.1, Settings.double(Settings.previewHideDelay))
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.dismissWindowPreview()
        }
    }

    private func dismissWindowPreview(animated: Bool = true) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        hoveredApp = nil
        lastHitTime = .distantPast  // next hover re-hit-tests immediately
        lastDismissAt = Date()
        guard let panel = previewPanel, panel.isVisible else {
            previewPanel = nil
            return
        }
        if !animated {
            panel.orderOut(nil)
            previewPanel = nil
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            self.previewPanel = nil
        })
    }

    struct WinInfo {
        let ax: AXUIElement
        let title: String
        let isMinimized: Bool
        let cgID: CGWindowID
    }

    private let previewQueue = DispatchQueue(label: "macindows.preview", qos: .userInteractive)

    private func showWindowPreview(for app: NSRunningApplication, at dockPt: NSPoint) {
        // AX calls into Electron apps can block for 100s of ms — keep them off the main thread
        previewQueue.async { [weak self] in
            let infos = Self.gatherWindows(of: app)
            DispatchQueue.main.async {
                guard let self = self, self.hoveredApp == app else { return }
                // Preview every windowed app; drop the previous preview if this one has no windows
                guard !infos.isEmpty else { self.dismissWindowPreview(animated: false); return }
                guard
                      self.isDockArea(NSEvent.mouseLocation) || (self.previewPanel?.isVisible ?? false) else { return }
                self.presentPreview(for: app, windows: infos, at: dockPt)
            }
        }
    }

    private static func gatherWindows(of app: NSRunningApplication) -> [WinInfo] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var axRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axRef) == .success,
              let axWindows = axRef as? [AXUIElement] else { return [] }
        var infos: [WinInfo] = []
        for axWin in axWindows {
            var titleRef: CFTypeRef?
            let title: String
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String, !t.isEmpty {
                title = t
            } else {
                title = app.localizedName ?? "Window"
            }
            var minRef: CFTypeRef?
            let isMin = AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minRef) == .success
                && (minRef as? Bool) == true
            var cgID: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWin, &cgID)
            infos.append(WinInfo(ax: axWin, title: title, isMinimized: isMin, cgID: cgID))
        }
        return infos
    }

    /// First-seen order of windows per app so cards don't shuffle when z-order changes.
    private var windowOrder: [pid_t: [CGWindowID]] = [:]

    private func stableOrder(_ infos: [WinInfo], for app: NSRunningApplication) -> [WinInfo] {
        let pid = app.processIdentifier
        var order = windowOrder[pid] ?? []
        let live = Set(infos.map { $0.cgID })
        order.removeAll { !live.contains($0) }
        for info in infos where info.cgID != 0 && !order.contains(info.cgID) { order.append(info.cgID) }
        windowOrder[pid] = order
        return infos.sorted { a, b in
            (order.firstIndex(of: a.cgID) ?? Int.max) < (order.firstIndex(of: b.cgID) ?? Int.max)
        }
    }

    private var lastDockPt = NSPoint.zero

    /// After an action on a card, rebuild the panel in place so it reflects the new state
    /// and stays open until the cursor leaves the Dock / panel area.
    private func refreshPreview(for app: NSRunningApplication) {
        hoveredApp = app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.hoveredApp == app else { return }
            self.showWindowPreview(for: app, at: self.lastDockPt)
        }
    }

    private func presentPreview(for app: NSRunningApplication, windows: [WinInfo], at dockPt: NSPoint) {
        let winInfos = stableOrder(windows, for: app)
        lastDockPt = dockPt
        let replacing = previewPanel != nil
        // Replace any panel still showing for the previously hovered app
        if let old = previewPanel { old.orderOut(nil); previewPanel = nil }

        // Show panel immediately with cached thumbnails (or app icon), then refresh async
        let windowData = winInfos.map {
            (ax: $0.ax, title: $0.title, thumbnail: WindowThumbnailer.cached[$0.cgID] ?? app.icon, isMinimized: $0.isMinimized)
        }

        let panel = WindowPreviewPanel()
        let imageViews = panel.display(windows: windowData, appName: app.localizedName ?? "App", appIcon: app.icon,
                                       onQuit: { [weak self] in
            app.terminate()
            self?.dismissWindowPreview(animated: false)
        }, onMinimizeAll: { [weak self] in
            self?.minimizeWindows(of: app)
            self?.refreshPreview(for: app)
        }, onClose: { [weak self] axWindow in
            // AX calls block until the target app answers — keep them off the main thread
            self?.previewQueue.async {
                var btnRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &btnRef) == .success,
                   let btn = btnRef {
                    AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
                }
            }
            self?.refreshPreview(for: app)
        }) { [weak self] axWindow in
            guard let self = self else { return }
            // Only the chosen window comes forward, never the whole app
            self.suppressAutoRestoreUntil = Date().addingTimeInterval(1.5)
            self.previewQueue.async {
                var mr: CFTypeRef?
                let isMin = AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &mr) == .success
                    && (mr as? Bool) == true
                // Windows-style toggle: visible window -> minimize, minimized -> restore
                if !isMin {
                    self.minimizeWindow(axWindow)
                    return
                }
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                DispatchQueue.main.async { app.activate() }
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
            self.refreshPreview(for: app)
        }

        // Refresh thumbnails for on-screen windows (minimized ones show the cached capture)
        let wanted = winInfos.enumerated().filter { !$0.element.isMinimized && $0.element.cgID != 0 }
        WindowThumbnailer.capture(windowIDs: wanted.map { $0.element.cgID }) { images in
            for (i, info) in wanted {
                guard let image = images[info.cgID], imageViews[i].window != nil else { continue }
                imageViews[i].image = image
            }
        }

        // Position next to the Dock on the screen the cursor is on
        guard let screen = screen(at: dockPt) else { return }
        let vis = screen.visibleFrame
        let sz = panel.frame.size
        if dockPt.y < vis.minY {
            let x = max(vis.minX, min(dockPt.x - sz.width / 2, vis.maxX - sz.width))
            panel.setFrameOrigin(NSPoint(x: x, y: vis.minY + 4))
        } else if dockPt.x < vis.minX {
            let y = max(vis.minY, min(dockPt.y - sz.height / 2, vis.maxY - sz.height))
            panel.setFrameOrigin(NSPoint(x: vis.minX + 4, y: y))
        } else {
            let y = max(vis.minY, min(dockPt.y - sz.height / 2, vis.maxY - sz.height))
            panel.setFrameOrigin(NSPoint(x: vis.maxX - sz.width - 4, y: y))
        }

        panel.alphaValue = replacing ? 1 : 0
        panel.orderFrontRegardless()
        if !replacing {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
        previewPanel = panel
    }

    // MARK: - AX Window Control

    /// Minimize a window. Fullscreen windows can't be minimized, so leave fullscreen first.
    private func minimizeWindow(_ w: AXUIElement) {
        var fsRef: CFTypeRef?
        let isFullscreen = AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fsRef) == .success
            && (fsRef as? Bool) == true
        if isFullscreen {
            AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, false as CFTypeRef)
            previewQueue.asyncAfter(deadline: .now() + 0.8) {
                let r = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            }
            return
        }
        let r = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, true as CFTypeRef)
    }

    private func isFocusedWindow(_ window: AXUIElement, of app: NSRunningApplication) -> Bool {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let focused = ref else { return false }
        if CFEqual(focused, window) { return true }
        // AX element identity is not stable across queries; compare CG window IDs
        var a: CGWindowID = 0, b: CGWindowID = 0
        _AXUIElementGetWindow(focused as! AXUIElement, &a)
        _AXUIElementGetWindow(window, &b)
        return a != 0 && a == b
    }

    private func toggleMinimize(of app: NSRunningApplication) {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], !windows.isEmpty else { return }

        let anyVisible = windows.contains {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue($0, "AXMinimized" as CFString, &v)
            return (v as? Bool) != true
        }
        for window in windows {
            AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, anyVisible as CFTypeRef)
        }
    }

    private func minimizeWindows(of app: NSRunningApplication) {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        // Snapshot first so the preview can still show these windows once minimized
        WindowThumbnailer.snapshotOnScreenWindows(of: app) { [weak self] in
            self?.previewQueue.async { for w in windows { self?.minimizeWindow(w) } }
        }
    }

    private func unminimizeWindows(of app: NSRunningApplication) {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        for w in windows { AXUIElementSetAttributeValue(w, "AXMinimized" as CFString, false as CFTypeRef) }
    }

    private func hasVisibleWindows(_ app: NSRunningApplication) -> Bool {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], !windows.isEmpty else {
            return true  // Can't confirm → assume visible so we don't block minimizing
        }
        return windows.contains {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue($0, "AXMinimized" as CFString, &v)
            return (v as? Bool) != true
        }
    }

    // MARK: - AX Dock Icon Detection

    private var lastHitPoint = NSPoint(x: -1e9, y: -1e9)
    private var lastHitApp: NSRunningApplication?
    private var lastHitTime = Date.distantPast

    private func axAppAtDockIcon(_ pt: NSPoint) -> NSRunningApplication? {
        guard AXIsProcessTrusted() else { return nil }
        // AX hit-testing is an IPC round trip; skip it for tiny moves
        if abs(pt.x - lastHitPoint.x) < 4, abs(pt.y - lastHitPoint.y) < 4,
           Date().timeIntervalSince(lastHitTime) < 0.5 {
            return lastHitApp
        }
        let app = axAppAtDockIconUncached(pt)
        lastHitPoint = pt; lastHitApp = app; lastHitTime = Date()
        return app
    }

    private func axAppAtDockIconUncached(_ pt: NSPoint) -> NSRunningApplication? {

        let system = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        let hit = AXUIElementCopyElementAtPosition(system, Float(pt.x), Float(primaryHeight - pt.y), &el)
        guard hit == .success, let element = el else {
            return nil
        }

        // Check element and its parent — the Dock icon might be a child element
        var candidates: [AXUIElement] = [element]
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
           let p = parentRef { candidates.append(p as! AXUIElement) }

        for candidate in candidates {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(candidate, "AXURL" as CFString, &val) == .success,
               let url = val as? URL {
                let path = url.standardizedFileURL.path
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleURL?.standardizedFileURL.path == path
                }) { return app }
            }
            if AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &val) == .success,
               let name = val as? String, !name.isEmpty {
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName == name
                }) { return app }
            }
        }
        return nil
    }

    private func dockAXWindowCount() -> Int {
        guard let dockPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier else { return 0 }
        let dock = AXUIElementCreateApplication(dockPID)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dock, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return 0 }
        return windows.count
    }

    /// Screen under a point. NSScreen.main is the key window's screen, wrong with several displays.
    private func screen(at pt: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(pt, $0.frame) } ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(pt) }
    }

    /// AX / CG coordinates flip Y against the PRIMARY display's height, not the current one.
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Dock area = inside the screen's frame but outside its visible frame (the Dock strip).
    private func isDockArea(_ pt: NSPoint) -> Bool {
        guard let screen = screen(at: pt) else { return false }
        let vis = screen.visibleFrame
        let f = screen.frame
        return (pt.y < vis.minY && pt.y >= f.minY - 1)
            || (pt.x < vis.minX && pt.x >= f.minX - 1)
            || (pt.x > vis.maxX && pt.x <= f.maxX + 1)
    }

    // MARK: - Login Item

    private func setupLoginItem() {
        if !isLoginItemEnabled() { try? SMAppService.mainApp.register() }
    }

    private func isLoginItemEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - Raw Scroll Event Tap

    private func setupRawScrollTap() {
        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return me.handleScrollEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            DTLog("[RawScroll] tap create FAILED. AXTrusted=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
            return
        }

        scrollEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        scrollRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        syncScrollTap()
        DTLog("[RawScroll] tap installed enabled=\(rawScrollEnabled) AXTrusted=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
    }

    private func handleScrollEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system disabled our tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DTLog("[RawScroll] tap disabled by system (\(type.rawValue)), re-enabling")
            if let tap = scrollEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        // Control + scroll in Finder icon view: resize icons (Windows-style grid zoom).
        // HID-level scroll events carry no modifier flags; read the live keyboard state.
        let ctrlDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
            || CGEventSource.flagsState(.hidSystemState).contains(.maskControl)
            || NSEvent.modifierFlags.contains(.control)
        if Settings.bool(Settings.finderZoom),
           ctrlDown,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            let dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            if dy != 0 { FinderIconZoom.shared.nudge(dy > 0 ? 1 : -1) }
            return nil
        }

        guard rawScrollEnabled else { return Unmanaged.passUnretained(event) }

        // Only intercept discrete mouse wheel events — leave trackpad/Magic Mouse alone
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if isContinuous {
            return Unmanaged.passUnretained(event)
        }

        // Kill ALL momentum / inertia events
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if momentumPhase != 0 {
            return nil  // swallow
        }

        // Read the raw notch deltas (typically ±1 per detent, or ±2–5 with acceleration)
        let rawY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let rawX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if rawY == 0 && rawX == 0 {
            return Unmanaged.passUnretained(event)
        }

        // Rewrite the ORIGINAL event in place: fixed lines per notch, no acceleration.
        // Swallowing it and posting a synthetic copy stops working on macOS 26+
        // (the copy is dropped or re-accelerated), so the real event carries on.
        let lines = AppDelegate.scrollLinesPerNotch
        let linearY: Int64 = rawY != 0 ? rawY.signum() * lines : 0
        let linearX: Int64 = rawX != 0 ? rawX.signum() * lines : 0

        // Windows uses ~40px per 3-line notch on a 96 DPI display ≈ ~13px/line
        let pxPerLine: Int64 = 13
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: linearY)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: linearY * pxPerLine)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(linearY))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: linearX)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: linearX * pxPerLine)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(linearX))

        // No phases — discrete, instantaneous scroll
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Finder Key Tap

    private func setupFinderKeyTap() {
        finderIsFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return me.handleFinderKey(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            DTLog("[FinderKeys] tap create FAILED")
            return
        }
        keyTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: keyTapWanted)
    }

    private var keyTapWanted: Bool {
        Settings.bool(Settings.finderBackspaceBack) || Settings.bool(Settings.finderEnterOpens)
            || Settings.bool(Settings.cmdShiftLanguage)
    }

    private func handleFinderKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            handleCmdShiftChord(event.flags)
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { cmdShiftArmed = false }   // any real key breaks the chord
        guard type == .keyDown, finderIsFront,
              event.getIntegerValueField(.eventSourceUserData) != AppDelegate.finderKeyMarker else {
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let isBackspace = key == 51
        let isReturn = key == 36 || key == 76
        let isF2 = key == 120
        let isEscape = key == 53
        guard isBackspace || isReturn || isF2 || isEscape else { return Unmanaged.passUnretained(event) }

        // A rename we started ends with Return or Escape: let it through
        if finderRenaming, isReturn || isEscape {
            finderRenaming = false
            return Unmanaged.passUnretained(event)
        }
        guard !isEscape,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              !finderIsEditingText() else { return Unmanaged.passUnretained(event) }

        if isBackspace, Settings.bool(Settings.finderBackspaceBack) {
            postKey(33, flags: .maskCommand)            // ⌘[  Back
            return nil
        }
        if isReturn, Settings.bool(Settings.finderEnterOpens) {
            postKey(125, flags: .maskCommand)           // ⌘↓  Open
            return nil
        }
        if isF2, Settings.bool(Settings.finderEnterOpens) {
            finderRenaming = true
            postKey(36, flags: [])                      // Return  Rename
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private static let finderKeyMarker: Int64 = 0x4D_4B_59  // "MKY"

    // MARK: - ⌘⇧ input language switch

    private func handleCmdShiftChord(_ flags: CGEventFlags) {
        guard Settings.bool(Settings.cmdShiftLanguage) else { cmdShiftArmed = false; return }
        let mods = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
        if mods == [.maskCommand, .maskShift] {
            cmdShiftArmed = true
        } else if cmdShiftArmed, !mods.contains(.maskCommand) || !mods.contains(.maskShift) {
            // Chord released with nothing else pressed in between
            cmdShiftArmed = false
            if mods.isEmpty || mods == [.maskCommand] || mods == [.maskShift] {
                DispatchQueue.main.async { self.selectNextInputSource() }
            }
        }
    }

    private func selectNextInputSource() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              list.count > 1,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        func id(_ s: TISInputSource) -> String {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        // Only real layouts / input modes, not palettes or handwriting
        let layouts = list.filter {
            guard let p = TISGetInputSourceProperty($0, kTISPropertyInputSourceType) else { return false }
            let t = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            return t == (kTISTypeKeyboardLayout as String) || t == (kTISTypeKeyboardInputMode as String)
        }
        guard layouts.count > 1 else { return }
        let cur = id(current)
        let idx = layouts.firstIndex { id($0) == cur } ?? -1
        TISSelectInputSource(layouts[(idx + 1) % layouts.count])
    }

    /// Finder ignores a rewritten key event, so post a real press instead.
    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: AppDelegate.finderKeyMarker)
        up.setIntegerValueField(.eventSourceUserData, value: AppDelegate.finderKeyMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// True while a Finder text field has focus (rename, search, Go to Folder). Capped at 50 ms.
    private func finderIsEditingText() -> Bool {
        guard let app = finderAX else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let el = ref else { return false }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        return role == kAXTextFieldRole as String || role == kAXTextAreaRole as String || role == kAXComboBoxRole as String
    }

    // MARK: - Mouse Speed Event Tap

    private func setupMouseSpeedTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return me.handleMouseSpeedEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            DTLog("[MouseSpeed] tap create FAILED")
            return
        }

        mouseSpeedTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mouseSpeedRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        // Only enable if multiplier is above 1
        CGEvent.tapEnable(tap: tap, enable: AppDelegate.mouseSpeedMultiplier > 1.001)
        DTLog("[MouseSpeed] tap installed multiplier=\(AppDelegate.mouseSpeedMultiplier)")
    }

    private func handleMouseSpeedEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if system disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = mouseSpeedTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let mult = AppDelegate.mouseSpeedMultiplier
        if mult <= 1.001 {
            return Unmanaged.passUnretained(event)
        }

        // Read the HID deltas
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)

        if dx == 0 && dy == 0 {
            return Unmanaged.passUnretained(event)
        }

        // event.location is where the cursor WOULD go with the original delta.
        // We add the extra movement: delta * (multiplier - 1)
        let extraX = dx * (mult - 1.0)
        let extraY = dy * (mult - 1.0)

        var newPos = CGPoint(
            x: event.location.x + CGFloat(extraX),
            y: event.location.y + CGFloat(extraY)
        )

        // Clamp to total display bounds (CG coordinates: top-left origin)
        let displayCount: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        var actualCount: UInt32 = 0
        CGGetActiveDisplayList(displayCount, &displays, &actualCount)
        var totalBounds = CGRect.zero
        for i in 0..<Int(actualCount) {
            totalBounds = totalBounds.union(CGDisplayBounds(displays[i]))
        }
        newPos.x = max(totalBounds.minX, min(newPos.x, totalBounds.maxX - 1))
        newPos.y = max(totalBounds.minY, min(newPos.y, totalBounds.maxY - 1))

        // Amplify the ORIGINAL event in place and let it continue down the pipeline.
        // Swallowing it and posting a synthetic copy breaks window dragging on
        // macOS 26+: WindowServer tracks drags from the real HID event stream and
        // ignores session-level synthetic drag events.
        event.location = newPos
        event.setDoubleValueField(.mouseEventDeltaX, value: dx * mult)
        event.setDoubleValueField(.mouseEventDeltaY, value: dy * mult)
        return Unmanaged.passUnretained(event)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        if let tap = scrollEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = scrollRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = keyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = mouseSpeedTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = mouseSpeedRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}

// MARK: - Private AX bridge for CG Window ID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// MARK: - Window Preview Panel

class WindowPreviewPanel: NSPanel {
    private let stack = NSStackView()          // cards row
    private let header = NSStackView()         // app name + actions
    private let column = NSStackView()         // header over cards
    private var cards: [HoverCardView] = []
    private var onQuit: (() -> Void)?
    private var onMinimizeAll: (() -> Void)?
    static let headerHeight: CGFloat = 26

    /// Instant hover highlight driven by our global mouse-move stream
    /// (tracking areas on a non-activating panel lag behind).
    func updateHover(screenPoint: NSPoint) {
        let inWindow = convertPoint(fromScreen: screenPoint)
        for card in cards {
            let local = card.convert(inWindow, from: nil)
            card.setHovered(card.bounds.contains(local))
        }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        // Above the Dock's own hover label so the preview covers it
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        contentView = blur

        stack.orientation = .horizontal
        stack.spacing = 10

        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(header)
        column.addArrangedSubview(stack)
        blur.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: blur.topAnchor),
            column.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            header.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20),
        ])
    }

    private func headerButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                         target: self, action: action)
        b.imagePosition = .imageLeading
        b.bezelStyle = .accessoryBarAction
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    @objc private func quitPressed() { onQuit?() }
    @objc private func minimizeAllPressed() { onMinimizeAll?() }

    private func buildHeader(appName: String, appIcon: NSImage?) {
        header.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let icon = NSImageView(image: appIcon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 18),
                                     icon.heightAnchor.constraint(equalToConstant: 18)])
        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(name)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(headerButton("Minimize All", symbol: "arrow.down.right.and.arrow.up.left", action: #selector(minimizeAllPressed)))
        header.addArrangedSubview(headerButton("Quit", symbol: "power", action: #selector(quitPressed)))
    }

    /// Returns the image view per window so thumbnails can be filled in later.
    @discardableResult
    func display(windows: [(ax: AXUIElement, title: String, thumbnail: NSImage?, isMinimized: Bool)],
                 appName: String, appIcon: NSImage?,
                 onQuit: @escaping () -> Void, onMinimizeAll: @escaping () -> Void,
                 onClose: @escaping (AXUIElement) -> Void,
                 onSelect: @escaping (AXUIElement) -> Void) -> [NSImageView] {
        self.onQuit = onQuit
        self.onMinimizeAll = onMinimizeAll
        buildHeader(appName: appName, appIcon: appIcon)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = []
        var imageViews: [NSImageView] = []

        let thumbW: CGFloat = 176
        let thumbH: CGFloat = 110
        let cardH: CGFloat = thumbH + 24

        for win in windows {
            let card = HoverCardView(frame: NSRect(x: 0, y: 0, width: thumbW, height: cardH))
            card.translatesAutoresizingMaskIntoConstraints = false

            let imgView = NSImageView(frame: .zero)
            imgView.image = win.thumbnail ?? appIcon
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 6
            imgView.layer?.masksToBounds = true
            if win.isMinimized { imgView.alphaValue = 0.75 }
            imgView.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(imgView)

            let label = NSTextField(labelWithString: win.title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(label)

            if win.isMinimized {
                let badge = NSTextField(labelWithString: " minimized ")
                badge.font = .systemFont(ofSize: 9, weight: .medium)
                badge.textColor = .white
                badge.wantsLayer = true
                badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
                badge.layer?.cornerRadius = 4
                badge.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.trailingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: -4),
                    badge.bottomAnchor.constraint(equalTo: imgView.bottomAnchor, constant: -4),
                ])
            }

            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: thumbW),
                card.heightAnchor.constraint(equalToConstant: cardH),
                imgView.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
                imgView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
                imgView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
                imgView.heightAnchor.constraint(equalToConstant: thumbH - 8),
                label.topAnchor.constraint(equalTo: imgView.bottomAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            ])

            let axWin = win.ax
            card.onClick = { onSelect(axWin) }
            card.onClose = { onClose(axWin) }
            card.isMinimized = win.isMinimized
            let menu = NSMenu()
            menu.addItem(MenuAction(win.isMinimized ? "Restore" : "Minimize") { onSelect(axWin) })
            menu.addItem(MenuAction("Close Window") { onClose(axWin) })
            menu.addItem(.separator())
            menu.addItem(MenuAction("Minimize All") { onMinimizeAll() })
            menu.addItem(MenuAction("Quit \(appName)") { onQuit() })
            card.contextMenu = menu
            stack.addArrangedSubview(card)
            cards.append(card)
            imageViews.append(imgView)
        }

        let cardsW = CGFloat(windows.count) * thumbW + CGFloat(windows.count - 1) * 10
        header.layoutSubtreeIfNeeded()
        let headerW = header.fittingSize.width
        let totalW = max(cardsW, headerW) + 20
        let totalH = cardH + 18 + Self.headerHeight + 6
        setContentSize(NSSize(width: totalW, height: totalH))
        return imageViews
    }
}

// MARK: - Window thumbnails (ScreenCaptureKit, needs Screen Recording permission)

enum WindowThumbnailer {
    /// Last capture per window, so minimized windows (which macOS cannot capture) still preview.
    static var cached: [CGWindowID: NSImage] = [:]
    static let maxSize = NSSize(width: 440, height: 260)

    /// One shareable-content enumeration, all captures in parallel.
    static func capture(windowIDs: [CGWindowID], completion: @escaping ([CGWindowID: NSImage]) -> Void) {
        guard #available(macOS 14.0, *), !windowIDs.isEmpty else { completion([:]); return }
        Task.detached(priority: .userInitiated) {
            var result: [CGWindowID: NSImage] = [:]
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                let wins = content.windows.filter { windowIDs.contains($0.windowID) }
                await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                    for w in wins { group.addTask { (w.windowID, await capture(w)) } }
                    for await (id, img) in group { if let img = img { result[id] = img } }
                }
            }
            let r = result
            DispatchQueue.main.async {
                r.forEach { cached[$0.key] = $0.value }
                completion(r)
            }
        }
    }

    /// Capture every on-screen window of the app into the cache, then run `then` on main.
    static func snapshotOnScreenWindows(of app: NSRunningApplication, then: @escaping () -> Void = {}) {
        guard #available(macOS 14.0, *) else { then(); return }
        let pid = app.processIdentifier
        Task.detached(priority: .utility) {
            var result: [CGWindowID: NSImage] = [:]
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                let wins = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
                await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                    for w in wins { group.addTask { (w.windowID, await capture(w)) } }
                    for await (id, img) in group { if let img = img { result[id] = img } }
                }
            }
            let r = result
            DispatchQueue.main.async {
                r.forEach { cached[$0.key] = $0.value }
                then()
            }
        }
    }

    @available(macOS 14.0, *)
    private static func capture(_ win: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = min(maxSize.width / max(win.frame.width, 1), maxSize.height / max(win.frame.height, 1), 1)
        cfg.width = max(Int(win.frame.width * scale * 2), 1)
        cfg.height = max(Int(win.frame.height * scale * 2), 1)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

/// NSMenuItem with a closure action
final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

class HoverCardView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenu: NSMenu?
    var isMinimized = false { didSet { minimizeButton.image = minimizeImage } }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    private var isHovered = false

    private var minimizeImage: NSImage? {
        NSImage(systemSymbolName: isMinimized ? "arrow.up.left.and.arrow.down.right.circle.fill" : "minus.circle.fill",
                accessibilityDescription: isMinimized ? "Restore" : "Minimize")
    }

    private func iconButton(_ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                         target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 18),
                                     b.heightAnchor.constraint(equalToConstant: 18)])
        return b
    }

    private lazy var minimizeButton = iconButton("minus.circle.fill", #selector(minimizePressed))
    private lazy var menuButton = iconButton("ellipsis.circle.fill", #selector(menuPressed))
    private lazy var closeButton = iconButton("xmark.circle.fill", #selector(closePressed))

    /// Small action strip, top-right, visible on hover
    private lazy var actions: NSStackView = {
        let st = NSStackView(views: [minimizeButton, menuButton, closeButton])
        st.orientation = .horizontal
        st.spacing = 2
        st.isHidden = true
        st.wantsLayer = true
        st.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        st.layer?.cornerRadius = 9
        st.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            st.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
        return st
    }()

    @objc private func closePressed() { onClose?() }
    @objc private func minimizePressed() { onClick?() }
    @objc private func menuPressed() {
        guard let menu = contextMenu else { return }
        let origin = NSPoint(x: menuButton.frame.minX, y: menuButton.frame.minY)
        menu.popUp(positioning: nil, at: origin, in: self)
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        actions.isHidden = !hovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        (isHovered ? NSColor.white.withAlphaComponent(0.15) : NSColor.white.withAlphaComponent(0.05)).setFill()
        path.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - File logger (~/Library/Logs/Macindows.log)
func DTLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Macindows.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Finder icon zoom (Control + scroll)

/// Coalesces scroll notches and asks Finder to change the front window's icon size.
final class FinderIconZoom {
    static let shared = FinderIconZoom()
    private var pending = 0
    private var scheduled = false
    private let queue = DispatchQueue(label: "macindows.finderzoom", qos: .userInteractive)
    private let stepPx = 8

    func nudge(_ direction: Int) {
        queue.async {
            self.pending += direction
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.04) { self.flush() }
        }
    }

    private func flush() {
        let delta = pending * stepPx
        pending = 0
        scheduled = false
        guard delta != 0 else { return }
        if setViaSlider(delta: delta) { return }
        setViaScript(delta: delta)
    }

    /// Finder's status-bar icon-size slider (View > Show Status Bar) redraws live.
    private func setViaSlider(delta: Int) -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return false }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return false }
        guard let slider = findSlider(in: win as! AXUIElement, depth: 0) else {
            return false
        }
        var vRef: CFTypeRef?, minRef: CFTypeRef?, maxRef: CFTypeRef?
        AXUIElementCopyAttributeValue(slider, kAXValueAttribute as CFString, &vRef)
        AXUIElementCopyAttributeValue(slider, kAXMinValueAttribute as CFString, &minRef)
        AXUIElementCopyAttributeValue(slider, kAXMaxValueAttribute as CFString, &maxRef)
        guard let cur = (vRef as? NSNumber)?.doubleValue else { return false }
        let lo = (minRef as? NSNumber)?.doubleValue ?? 16
        let hi = (maxRef as? NSNumber)?.doubleValue ?? 512
        let next = max(lo, min(hi, cur + Double(delta)))
        let r = AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, next as CFTypeRef)
        return r == .success
    }

    private func findSlider(in el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == kAXSliderRole as String { return el }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        for k in kids { if let f = findSlider(in: k, depth: depth + 1) { return f } }
        return nil
    }

    /// Fallback: change the view option, then bounce the view so Finder redraws.
    private func setViaScript(delta: Int) {
        let src = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return
            set w to front Finder window
            if current view of w is not icon view then return
            set o to icon view options of w
            set s to (icon size of o) + (\(delta))
            if s < 16 then set s to 16
            if s > 512 then set s to 512
            set icon size of o to s
            set current view of w to list view
            set current view of w to icon view
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err = err { DTLog("[FinderZoom] \(err)") }
    }
}
