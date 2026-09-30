import AppKit
import SwiftUI
import AnomalousCore

/// AppKit host for the menu bar. Replaces `MenuBarExtra(.window)`, whose
/// SwiftUI-positioned panel detaches from the icon (drops low and shoves left)
/// because it can't stay anchored while the content resizes — proven on-device.
/// An `NSStatusItem` + `NSPopover` (what Tailscale and every well-behaved menu
/// use) grows from its anchor: the popover resizes to fit the SwiftUI content
/// (expand-in-place, no jiggle) AND stays pinned under the icon. No existing
/// surface could be extended to fix this — MenuBarExtra owns its own placement
/// and exposes no anchor control — so this host is net-new.
///
/// It also becomes the single owner of window opening, because `openWindow`,
/// `openSettings`, and `dismiss` are scene-graph-only and are inert inside an
/// AppKit-hosted `NSHostingController`. The home/welcome windows are therefore
/// AppKit `NSWindow`s (hosting the same SwiftUI views), and views ask for them
/// through `AppState` signals or `AppDelegate.shared`, never the environment.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Bridge for popover-hosted SwiftUI views (which have no scene actions) to
    /// close the popover / open Settings. Set once the delegate is live.
    static weak var shared: AppDelegate?

    private let appState = AppState.shared
    // Sparkle auto-update, owned for the app's lifetime (was `@State` on the
    // App). Started at init so background checks run from launch; the "Check
    // for Updates…" control lives in the popover footer (AnomalyListView).
    private let updater = UpdaterController()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var homeWindowController: NSWindowController?
    private var welcomeWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?

    // Cached menu-bar marks (same asset-catalog images the SwiftUI label used).
    private lazy var quietImage: NSImage? = {
        let image = NSImage(named: "StatusMark")
        image?.isTemplate = true          // system tints it to the bar
        return image
    }()
    private lazy var activeImage: NSImage? = {
        let image = NSImage(named: "StatusActive")
        image?.isTemplate = false         // keep the red spike its own color
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // The popover hosts the live cards. `.preferredContentSize` makes the
        // hosting controller report the SwiftUI content's size, so the popover
        // resizes with it and stays anchored — the whole point of the swap.
        // Fixed width, intrinsic height: the popover is a narrow card column
        // (like the old MenuBarExtra `.frame(width: 420)`); `.preferredContentSize`
        // then lets its HEIGHT grow/shrink with the cards, anchored under the icon.
        let host = NSHostingController(rootView:
            AnomalyListView(appState: appState, updater: updater).frame(width: 420))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        updateStatusIcon()

        appState.startMonitoring()          // idempotent; runs even if the popover never opens

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            openWelcome()
        }

        // Reactive plumbing (AppState is @Observable): keep the icon in sync
        // with the anomaly state, and open Home when a notification deep-link
        // (or an in-app request) sets `pendingHomeSection`.
        trackAnomalies()
        trackDeepLink()

        // The welcome window sets `hasCompletedOnboarding`; close it when done
        // (a hosting-controller `dismiss()` doesn't reliably close an NSWindow).
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    // MARK: - Status item + popover

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let quiet = appState.anomalies.isEmpty
        button.image = quiet ? quietImage : activeImage
        button.image?.accessibilityDescription = quiet
            ? "Anomalous: nothing is wrong"
            : "Anomalous: \(appState.anomalies.count) \(appState.anomalies.count == 1 ? "anomaly" : "anomalies") detected"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Accessory (LSUIElement) apps open behind the frontmost app; bring
            // the popover forward so its controls are immediately interactive.
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Popover-hosted views call this instead of the (inert) `dismiss()`.
    func closePopover() { popover.performClose(nil) }

    // MARK: - Windows

    /// Open (or focus) the Home window. `pendingHomeSection` already carries
    /// which section to show — HomeView reads and clears it once on screen.
    func openHome() {
        if homeWindowController == nil {
            let host = NSHostingController(rootView: HomeView(appState: appState))
            let window = NSWindow(contentViewController: host)
            window.title = "Anomalous"
            window.identifier = NSUserInterfaceItemIdentifier("history")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 660))
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("AnomalousHome")
            homeWindowController = NSWindowController(window: window)
        }
        homeWindowController?.showWindow(nil)
        homeWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openWelcome() {
        if welcomeWindowController == nil {
            let host = NSHostingController(rootView: OnboardingView(appState: appState))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome to Anomalous"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindowController = NSWindowController(window: window)
        }
        welcomeWindowController?.showWindow(nil)
        welcomeWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Share one settings window across the popover, account links, and ⌘,.
    func openSettingsWindow() {
        closePopover()
        if settingsWindowController == nil {
            let host = NSHostingController(rootView: SettingsView(appState: appState))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Anomalous Settings"
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc nonisolated private func defaultsChanged() {
        Task { @MainActor [weak self] in
            self?.closeCompletedOnboarding()
        }
    }

    private func closeCompletedOnboarding() {
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
           welcomeWindowController?.window?.isVisible == true {
            welcomeWindowController?.close()
        }
    }

    // MARK: - Observation (Observation framework → AppKit)

    private func trackAnomalies() {
        withObservationTracking {
            _ = appState.anomalies.count
        } onChange: { [weak self] in
            // onChange fires just BEFORE the value updates; hop to main and
            // re-read, then re-register (tracking is single-shot).
            DispatchQueue.main.async {
                self?.updateStatusIcon()
                self?.trackAnomalies()
            }
        }
    }

    private func trackDeepLink() {
        withObservationTracking {
            _ = appState.pendingHomeSection
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                if AppState.shared.pendingHomeSection != nil { self?.openHome() }
                self?.trackDeepLink()
            }
        }
    }
}
