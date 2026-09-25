@preconcurrency import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import AVFoundation
import Carbon.HIToolbox
import CoreImage
import CryptoKit
import Foundation
import IOKit.pwr_mgt
import LocalAuthentication
import Security
import ServiceManagement
import SoftLockCore
import UniformTypeIdentifiers

private let appIdentifier = "com.softlock.agent-shield"

/// Single source of truth for release notes. The newest entry comes first; the About pane
/// renders this list, and `CHANGELOG.md` mirrors it. Bump `CFBundleShortVersionString` in
/// `scripts/package-app.sh` to match the top entry when cutting a release.
private enum Changelog {
    struct Entry {
        let version: String
        let date: String
        let changes: [String]
    }

    static let entries: [Entry] = [
        Entry(
            version: "0.5.1",
            date: "2026-09-25",
            changes: [
                "Face unlock waits for you: the lock badge is now a camera button, and pressing Space starts a scan too. Scanning automatically meant locking the Mac and walking away could unlock it again on the way out. Turn Scan automatically when locked back on in Settings > Security if you prefer the old behaviour.",
                "Lock-screen status messages sit at the bottom of the screen, so a message appearing never shifts the passcode layout.",
                "Locking again right after a face unlock no longer shows the last scan's green tick."
            ]
        ),
        Entry(
            version: "0.5.0",
            date: "2026-09-25",
            changes: [
                "SoftLock now updates itself: it checks daily for a new version, shows what changed, and installs only when you agree. Check for Updates... is in the menu bar menu.",
                "The lock-screen camera self-view sits where the padlock badge is, above your name, instead of at the bottom of the screen."
            ]
        ),
        Entry(
            version: "0.4.0",
            date: "2026-09-25",
            changes: [
                "New optional Unlock with Face (off by default): guided ring-style enrollment in Settings with live feedback and a Test Recognition button, on-device ArcFace recognition, encrypted storage, and a pause after 10 missed scans. The lock screen shows a small live self-view ring that turns green with a tick as it unlocks, and a face that is present but not recognized can be saved as a failed-attempt photo. It is less secure than Touch ID or your passcode, which always keep working.",
                "Liveness checks are selectable: Light (default) rejects a photo or a screen while you sit still, Heavy also wants a blink or a slight head turn, Off skips the check. A window or glass partition behind you no longer counts as a phone held up to the camera.",
                "Lock-screen status messages now sit on a readable dark pill on any wallpaper, and the Touch ID and delete keys match the digit keys exactly."
            ]
        ),
        Entry(
            version: "0.3.1",
            date: "2026-07-31",
            changes: [
                "Logging back into macOS releases SoftLock again — the trusted-unlock check was rejecting every unlock, which left the forgot-PIN escape hatch dead.",
                "Connecting or disconnecting a display during the \"too many attempts\" wait no longer clears the wait.",
                "Touch ID now respects that wait too, instead of offering a way around it.",
                "Failed-attempt photos no longer freeze the lock screen while the camera starts, and rapid wrong entries no longer leave the camera running.",
                "The passcode prompt is always placed on one display, even when macOS reports no focused screen."
            ]
        ),
        Entry(
            version: "0.3.0",
            date: "2026-06-29",
            changes: [
                "Lock screen fits small MacBook displays: the clock, badge and keypad scale down on shorter screens.",
                "Touch ID now sits inside the keypad (the empty key next to 0) instead of taking a separate row.",
                "Permissions only flag what your setup actually needs — Screen Recording shows \"not needed\" unless Auto appearance runs over a see-through background — and each missing permission has a Grant button that opens the right System Settings pane.",
                "Failed-attempt photos moved next to the capture toggle in Security, with thumbnails of the latest captures (click to open) and an Open Folder button."
            ]
        ),
        Entry(
            version: "0.2.0",
            date: "2026-06-29",
            changes: [
                "Mac no longer locks itself while SoftLock is active — an idle-sleep guard keeps the system from sleeping the display and dropping to the macOS login window.",
                "Trusted macOS-login escape hatch: closing the lid or using the macOS lock shortcut now releases SoftLock when you log back in, so you never enter a password twice or get stranded behind a forgotten PIN.",
                "Re-locks automatically after an unexpected quit while locked, instead of exposing the desktop."
            ]
        ),
        Entry(
            version: "0.1.0",
            date: "2026-06-26",
            changes: [
                "Initial release: menu bar lock with password or 4/6-digit PIN, one-time recovery code, Touch ID unlock, customizable lock-screen background, a system-wide lock shortcut, and optional failed-attempt camera photos."
            ]
        )
    ]
}

private enum LockTrigger {
    case manual
    case hotKey(LockShortcut)
}

/// Holds an IOKit power assertion while SoftLock's lock screen is up, so macOS
/// does not run its own idle timers and drop to the real login-window lock.
///
/// `PreventUserIdleDisplaySleep` is what `caffeinate -d` uses: it suppresses the
/// idle-triggered display sleep *and* the screen saver, which is what otherwise
/// engages the macOS password lock and defeats SoftLock's purpose.
///
/// Only idle-triggered sleep is suppressed. Closing the lid (clamshell) and a
/// critical-battery sleep cannot be blocked by power assertions and are left to
/// macOS. The assertion is process-bound, so it is released automatically if the
/// app exits while still locked.
@MainActor
final class IdleSleepGuard {
    private var assertionID = IOPMAssertionID(0)
    private var active = false

    func begin() {
        guard !active else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SoftLock screen is active" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            active = true
            AppLog.write("idle-sleep guard begin")
        } else {
            AppLog.write("idle-sleep guard begin failed: \(result)")
        }
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        active = false
        AppLog.write("idle-sleep guard end")
    }
}

private enum PermissionKind {
    case accessibility
    case screenRecording
    case camera

    /// System Settings → Privacy & Security deep-link anchor.
    var privacyAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .camera: return "Privacy_Camera"
        }
    }
}

private struct PermissionStatus {
    let name: String
    let kind: PermissionKind
    let ok: Bool
    /// False when the feature that needs this permission is turned off, so we don't nag the
    /// user to grant something SoftLock won't use in their current configuration.
    let required: Bool
    let detail: String
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PasswordStore()
    private var statusItem: NSStatusItem?
    private var locker: LockerController?
    private var setupWindow: SetupWindowController?
    private var mainWindow: MainWindowController?
    private var isLocked = false
    private var observedVerifiedMacOSLock = false
    private let idleSleepGuard = IdleSleepGuard()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching")
        UpdaterController.shared.start()
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = NSMenu()

        if CommandLine.arguments.contains("--reset-password") {
            try? store.delete()
        }

        store.deleteIfUnreadable()
        configureStatusItem()
        registerLockShortcut()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registerLockShortcut),
            name: AppSettings.shortcutChangedNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(macOSScreenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(macOSScreenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // If a prior run died (crash / force-quit / "backdoor") while locked, the marker is
        // still on disk: re-lock immediately so a relaunch never lands on an open desktop.
        if store.isConfigured, LockState.isMarked {
            AppLog.write("relaunch while marked locked → re-locking")
            lock(trigger: .manual)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !self.store.isConfigured {
                self.showPasswordSetup()
            }
        }
    }

    @objc private func macOSScreenLocked() {
        guard isLocked else { return }
        guard macOSSessionIsLocked == true else {
            AppLog.write("rejected unverified macOS screen-locked notification")
            return
        }

        observedVerifiedMacOSLock = true
        AppLog.write("verified macOS screen lock")
    }

    @objc private func macOSScreenUnlocked() {
        AppLog.write("macOS screen unlocked")
        guard isLocked else { return }
        guard observedVerifiedMacOSLock, macOSSessionIsLocked == false else {
            AppLog.write("rejected unverified macOS screen-unlocked notification")
            return
        }

        observedVerifiedMacOSLock = false
        AppLog.write("standing down SoftLock after trusted macOS unlock")
        locker?.standDown()
    }

    /// `nil` only when the session state can't be read at all, so callers can fail closed.
    ///
    /// CoreGraphics publishes `CGSSessionScreenIsLocked` *only while the session is locked*;
    /// an absent key means unlocked. Mapping the absent key to `nil` instead of `false` made
    /// `macOSScreenUnlocked`'s `== false` check unsatisfiable, which silently disabled the
    /// trusted-macOS-unlock stand-down — and with it the forgot-PIN escape hatch.
    private var macOSSessionIsLocked: Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }

        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isLocked else {
            AppLog.write("termination rejected while locked")
            return .terminateCancel
        }

        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if store.isConfigured {
                showMain()
            } else {
                showPasswordSetup()
            }
        }

        return true
    }

    private func configureStatusItem() {
        AppLog.write("configureStatusItem")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = LockIcon.make()
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "SoftLock"
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let lockItem = NSMenuItem(title: "Lock Now", action: #selector(lockNow), keyEquivalent: "l")
        lockItem.target = self
        lockItem.isEnabled = store.isConfigured
        menu.addItem(lockItem)

        let openItem = NSMenuItem(title: "Open SoftLock", action: #selector(showMain), keyEquivalent: "")
        openItem.target = self
        openItem.isEnabled = store.isConfigured
        menu.addItem(openItem)

        let setupItem = NSMenuItem(title: store.isConfigured ? "Change Passcode..." : "Set Passcode...", action: #selector(showPasswordSetup), keyEquivalent: ",")
        setupItem.target = self
        menu.addItem(setupItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SoftLock", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = makeMenu()
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func registerLockShortcut() {
        HotKeyCenter.shared.register(AppSettings.shared.lockShortcuts) { [weak self] shortcut in
            self?.lock(trigger: .hotKey(shortcut))
        }
    }

    @objc private func lockNow() {
        lock(trigger: .manual)
    }

    private func lock(trigger: LockTrigger) {
        AppLog.write("lockNow requested")
        guard store.isConfigured, !isLocked else { return }
        setupWindow?.close()
        setupWindow = nil

        if locker == nil {
            locker = LockerController(
                store: store,
                settings: AppSettings.shared,
                onUnlock: { [weak self] recoveryUsed in
                    self?.handleUnlock(recoveryUsed: recoveryUsed)
                }
            )
        }

        isLocked = true
        observedVerifiedMacOSLock = macOSSessionIsLocked == true
        LockState.mark()
        idleSleepGuard.begin()
        locker?.lock(trigger: trigger)
    }

    @objc private func showPasswordSetup() {
        AppLog.write("showPasswordSetup")
        guard !isLocked else { return }

        let controller = SetupWindowController(store: store) { [weak self] recoveryCode in
            self?.refreshMenu()
            self?.showRecoveryCode(recoveryCode)
        }

        setupWindow = controller
        controller.show()
    }

    @objc private func showMain() {
        AppLog.write("showMain")
        guard !isLocked else { return }

        if mainWindow == nil {
            mainWindow = MainWindowController(
                settings: AppSettings.shared,
                onLock: { [weak self] in self?.lockNow() },
                onChangePasscode: { [weak self] in self?.showPasswordSetup() },
                onDeleteApp: { [weak self] in self?.deleteAppData() }
            )
        }
        mainWindow?.show()
    }

    @objc private func quit() {
        guard !isLocked else { return }
        NSApp.terminate(nil)
    }

    /// Full local uninstall: wipe the passcode, settings and stored data, then revoke the
    /// TCC permission grants so a future build/install starts from a clean slate. Quits at
    /// the end because revoking our own Accessibility grant mid-run isn't recoverable.
    private func deleteAppData() {
        guard !isLocked else { return }
        AppLog.write("deleteAppData requested")

        try? store.delete()
        AppSettings.shared.eraseForUninstall()
        SoftLockData.eraseStoredFiles()
        FaceUnlockStore.eraseAll()
        PermissionsReset.resetAll()

        NSApp.terminate(nil)
    }

    private func handleUnlock(recoveryUsed: Bool) {
        AppLog.write("handleUnlock recoveryUsed=\(recoveryUsed)")
        isLocked = false
        LockState.clear()
        idleSleepGuard.end()

        if recoveryUsed {
            try? store.delete()
            refreshMenu()
            showPasswordSetup()
        }
    }

    private func showRecoveryCode(_ code: String) {
        let alert = NSAlert()
        alert.messageText = "Save your recovery code"
        alert.informativeText = "Store this in your password manager:\n\n\(code)\n\nIf you ever forget your password, enter this code on the lock screen to set a new one."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@main
private enum SoftLockMain {
    @MainActor
    private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class MainWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let settings: AppSettings
    private let onLock: () -> Void
    private let onChangePasscode: () -> Void
    private let onDeleteApp: () -> Void
    private let window: NSWindow

    private let titleField = NSTextField()
    private let backgroundKindPopup = NSPopUpButton()
    private let blurSlider = NSSlider(value: 0.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let blurValueLabel = NSTextField(labelWithString: "")
    private let backgroundColorStack = NSStackView()
    private var backgroundColorButtons: [NSButton] = []
    private let backgroundMediaButton = NSButton(title: "Choose...", target: nil, action: nil)
    private let appleWallpapersButton = NSButton(title: "Apple...", target: nil, action: nil)
    private let backgroundMediaClearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let backgroundMediaLabel = NSTextField(labelWithString: "")
    private let inputAppearancePopup = NSPopUpButton()
    private let liquidGlassInputsSwitch = NSSwitch()
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginStatusLabel = NSTextField(labelWithString: "")
    private let launchAtLoginSettingsButton = NSButton(title: "Open Settings...", target: nil, action: nil)
    private var shortcutRecorders: [ShortcutRecorderView] = []
    private let touchIDSwitch = NSSwitch()
    private let captureSwitch = NSSwitch()
    private let maxPhotosStepper = NSStepper()
    private let maxPhotosLabel = NSTextField(labelWithString: "")
    private let permissionsStack = NSStackView()

    private let headerLabel = NSTextField(labelWithString: "")
    private let contentContainer = NSView()
    private var sidebarItems: [NSView] = []
    private var sidebarLabels: [NSTextField] = []
    private var selectedIndex = 0
    private var launchAtLoginError: String?
    private var wallpaperPicker: WallpaperPickerWindowController?
    private var appearanceObservation: NSKeyValueObservation?
    private var titleFieldSizeConstraints: [NSLayoutConstraint] = []

    private struct Pane {
        let title: String
        let symbol: String
        let tint: NSColor
    }

    private let panes: [Pane] = [
        Pane(title: "General", symbol: "gearshape.fill", tint: .systemGray),
        Pane(title: "Security", symbol: "lock.shield.fill", tint: .systemBlue),
        Pane(title: "About", symbol: "info.circle.fill", tint: .systemTeal)
    ]

    init(
        settings: AppSettings,
        onLock: @escaping () -> Void,
        onChangePasscode: @escaping () -> Void,
        onDeleteApp: @escaping () -> Void
    ) {
        self.settings = settings
        self.onLock = onLock
        self.onChangePasscode = onChangePasscode
        self.onDeleteApp = onDeleteApp
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    func show() {
        // Refresh the visible pane so values reflect any external changes.
        selectPane(selectedIndex)
        // Only place the window when it first appears — re-centering an already-open window
        // (e.g. picking "Settings" from the menu again) made it jump under the user.
        if !window.isVisible {
            window.centerOnActiveScreen()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        window.title = "SoftLock"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titleVisibility = .hidden

        // Card fills/borders are baked into CALayers as fixed CGColors, so a light/dark switch
        // while the window is open would leave them stale. Rebuild the pane when it flips.
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    self.selectPane(self.selectedIndex)
                }
            }
        }

        let sidebar = makeSidebar()
        let content = makeContentArea()

        let root = NSView()
        root.addSubview(sidebar)
        root.addSubview(content)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        selectPane(0)
    }

    // MARK: - Sidebar

    private func makeSidebar() -> NSView {
        let backing = NSVisualEffectView()
        backing.material = .sidebar
        backing.blendingMode = .behindWindow
        backing.state = .active

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, pane) in panes.enumerated() {
            let item = makeSidebarItem(pane: pane, index: index)
            sidebarItems.append(item)
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            item.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }

        backing.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backing.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: backing.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: backing.topAnchor, constant: 52)
        ])
        return backing
    }

    private func makeSidebarItem(pane: Pane, index: Int) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        let tile = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)?
            .withSymbolConfiguration(tile)
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = pane.tint.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.layer?.cornerCurve = .continuous
        imageView.contentTintColor = .white
        // Keep the glyph centred and proportionally inset so the tile reads as a clean 1:1
        // square (the colored background is square; the symbol sits symmetrically inside it).
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: pane.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        sidebarLabels.append(label)

        let row = NSStackView(views: [imageView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let button = NSButton(title: "", target: self, action: #selector(sidebarItemClicked(_:)))
        button.tag = index
        button.isBordered = false
        button.isTransparent = true
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func sidebarItemClicked(_ sender: NSButton) {
        selectPane(sender.tag)
    }

    private func selectPane(_ index: Int) {
        selectedIndex = index
        for (i, item) in sidebarItems.enumerated() {
            let selected = i == index
            item.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            if i < sidebarLabels.count {
                sidebarLabels[i].textColor = selected ? .white : .labelColor
            }
        }
        headerLabel.stringValue = panes[index].title

        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let pane: NSView
        switch index {
        case 0: pane = buildGeneralPane()
        case 1: pane = buildSecurityPane()
        default: pane = buildAboutPane()
        }
        pane.translatesAutoresizingMaskIntoConstraints = false

        // The General/About panes are taller than the window once a few shortcuts are added,
        // so host the pane in a scroll view instead of letting it run off the bottom edge.
        // The flipped document keeps the pane pinned to the top.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pane)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        contentContainer.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            pane.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            pane.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            pane.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            pane.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
    }

    // MARK: - Content area

    private func makeContentArea() -> NSView {
        let backing = NSVisualEffectView()
        backing.material = .contentBackground
        backing.blendingMode = .behindWindow
        backing.state = .active

        headerLabel.font = .systemFont(ofSize: 28, weight: .bold)
        headerLabel.textColor = .labelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        backing.addSubview(headerLabel)
        backing.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: backing.leadingAnchor, constant: 28),
            headerLabel.topAnchor.constraint(equalTo: backing.topAnchor, constant: 42),
            contentContainer.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16),
            contentContainer.bottomAnchor.constraint(equalTo: backing.bottomAnchor)
        ])
        return backing
    }

    // MARK: - Panes

    private func buildGeneralPane() -> NSView {
        let lockButton = NSButton(title: "Lock Now", target: self, action: #selector(lockTapped))
        lockButton.bezelStyle = .rounded
        lockButton.controlSize = .large
        lockButton.contentTintColor = .controlAccentColor

        configure(titleField, placeholder: "Lock screen title")
        titleField.stringValue = settings.lockTitle
        titleField.delegate = self
        titleField.alignment = .right
        // Activated once: the field is reused on every pane rebuild, so re-adding the
        // constraints each time piled up duplicates. The fixed height also stops the
        // borderless glass style from collapsing to a single text line.
        if titleFieldSizeConstraints.isEmpty {
            titleFieldSizeConstraints = [
                titleField.widthAnchor.constraint(equalToConstant: 230),
                titleField.heightAnchor.constraint(equalToConstant: 26)
            ]
            NSLayoutConstraint.activate(titleFieldSizeConstraints)
        }

        let backgroundControl = makeBackgroundEffectControl()
        let inputAppearanceControl = makeInputAppearanceControl()
        let liquidGlassInputsControl = makeLiquidGlassInputsControl()
        let launchAtLoginControl = makeLaunchAtLoginControl()

        let pane = verticalGroups([
            makeGroup([makeRow("Lock this Mac", control: lockButton)]),
            makeGroup([
                makeRow("Lock screen title", control: titleField),
                makeRow("Background effect", control: backgroundControl, height: 156),
                makeRow("Input appearance", control: inputAppearanceControl),
                makeRow("Liquid glass inputs", control: liquidGlassInputsControl),
                makeRow("Open at Login", control: launchAtLoginControl)
            ]),
            makeGroup(makeShortcutRows())
        ])
        pane.addArrangedSubview(footnote("Shortcuts work anywhere, even when SoftLock isn't focused. Add an alternate combo for keyboards with a different layout."))
        return pane
    }

    /// One row per configured lock shortcut (recorder + remove button when there is more
    /// than one), followed by an "add" row. Rows are rebuilt via `selectPane` whenever
    /// shortcuts are added or removed.
    private func makeShortcutRows() -> [NSView] {
        shortcutRecorders = []
        var rows: [NSView] = []
        let shortcuts = settings.lockShortcuts

        for (index, shortcut) in shortcuts.enumerated() {
            let recorder = ShortcutRecorderView(shortcut: shortcut)
            recorder.glassEnabled = settings.liquidGlassInputsEnabled
            recorder.onChange = { [weak self] changed in
                self?.shortcutChanged(changed, at: index)
            }
            recorder.onRecordingChange = { recording in
                if recording {
                    HotKeyCenter.shared.suspend()
                } else {
                    HotKeyCenter.shared.resume()
                }
            }
            shortcutRecorders.append(recorder)

            let control: NSView
            if shortcuts.count > 1 {
                let remove = NSButton(
                    image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove shortcut") ?? NSImage(),
                    target: self,
                    action: #selector(removeShortcutTapped(_:))
                )
                remove.tag = index
                remove.isBordered = false
                remove.contentTintColor = .tertiaryLabelColor
                let stack = NSStackView(views: [recorder, remove])
                stack.orientation = .horizontal
                stack.spacing = 8
                control = stack
            } else {
                control = recorder
            }
            rows.append(makeRow(index == 0 ? "Lock shortcut" : "Alternate shortcut", control: control))
        }

        let add = NSButton(title: "Add", target: self, action: #selector(addShortcutTapped))
        add.bezelStyle = .rounded
        rows.append(makeRow("Add another shortcut", control: add))
        return rows
    }

    private func shortcutChanged(_ shortcut: LockShortcut, at index: Int) {
        var all = settings.lockShortcuts
        guard all.indices.contains(index) else { return }
        // Refuse a combo that's already taken by another slot; revert the recorder's label.
        if all.enumerated().contains(where: { $0.offset != index && $0.element.sameKey(as: shortcut) }) {
            NSSound.beep()
            if shortcutRecorders.indices.contains(index) {
                shortcutRecorders[index].update(all[index])
            }
            return
        }
        all[index] = shortcut
        settings.lockShortcuts = all
    }

    @objc private func addShortcutTapped() {
        var all = settings.lockShortcuts
        // Reuse a still-unset slot instead of stacking empty ones.
        if let pending = all.firstIndex(where: { !$0.isSet }) {
            if shortcutRecorders.indices.contains(pending) {
                shortcutRecorders[pending].beginRecording()
            }
            return
        }
        all.append(.unset)
        settings.lockShortcuts = all
        selectPane(selectedIndex)
        shortcutRecorders.last?.beginRecording()
    }

    @objc private func removeShortcutTapped(_ sender: NSButton) {
        var all = settings.lockShortcuts
        guard all.indices.contains(sender.tag) else { return }
        all.remove(at: sender.tag)
        settings.lockShortcuts = all
        selectPane(selectedIndex)
    }

    private func buildSecurityPane() -> NSView {
        let available = BiometricAuth.isAvailable
        touchIDSwitch.state = settings.useTouchID ? .on : .off
        touchIDSwitch.target = self
        touchIDSwitch.action = #selector(touchIDChanged)
        touchIDSwitch.isEnabled = available

        let unlockRow = makeRow(available ? "Unlock with Touch ID" : "Unlock with Touch ID (unavailable)", control: touchIDSwitch)

        let passcodeValue = NSTextField(labelWithString: passcodeDescription())
        passcodeValue.font = .systemFont(ofSize: 13)
        passcodeValue.textColor = .secondaryLabelColor
        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changePasscodeTapped))
        changeButton.bezelStyle = .rounded
        let passcodeControl = NSStackView(views: [passcodeValue, changeButton])
        passcodeControl.spacing = 8

        captureSwitch.state = settings.capturePhotoOnFailure ? .on : .off
        captureSwitch.target = self
        captureSwitch.action = #selector(captureChanged)

        maxPhotosStepper.minValue = 1
        maxPhotosStepper.maxValue = 100
        maxPhotosStepper.increment = 1
        maxPhotosStepper.integerValue = settings.maxFailedAttemptPhotos
        maxPhotosStepper.target = self
        maxPhotosStepper.action = #selector(maxPhotosChanged)
        maxPhotosLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        maxPhotosLabel.textColor = .secondaryLabelColor
        maxPhotosLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        updateMaxPhotosLabel()
        let maxPhotosControl = NSStackView(views: [maxPhotosLabel, maxPhotosStepper])
        maxPhotosControl.spacing = 8

        let permButton = NSButton(title: "Check", target: self, action: #selector(checkPermissions))
        permButton.bezelStyle = .rounded
        permissionsStack.orientation = .vertical
        permissionsStack.alignment = .trailing
        permissionsStack.spacing = 3
        updatePermissionsLabel()
        let permControl = NSStackView(views: [permissionsStack, permButton])
        permControl.spacing = 10
        permControl.alignment = .centerY

        return verticalGroups([
            makeGroup([
                unlockRow,
                makeRow("Passcode", control: passcodeControl)
            ]),
            makeGroup([
                FaceUnlockSettingsView()
            ]),
            makeGroup([
                makeRow("Capture a photo on failed unlock", control: captureSwitch),
                makeRow("Photos to keep", control: maxPhotosControl),
                makeFailedPhotosRow(),
                makeRow("Permissions", control: permControl, height: 84)
            ])
        ])
    }

    /// A two-line row for failed-attempt photos: the label and an Open Folder button on top,
    /// and below them a 3-up grid of larger, clickable thumbnails of the latest captures.
    private func makeFailedPhotosRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Recent photos")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let openButton = NSButton(title: "Open Folder…", target: self, action: #selector(openFailedAttempts))
        openButton.bezelStyle = .rounded
        openButton.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(openButton)

        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = 10
        strip.alignment = .centerY
        strip.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(strip)

        let photos = FailedAttemptStore.recentPhotos(limit: 3)
        if photos.isEmpty {
            let empty = NSTextField(labelWithString: "No photos captured yet")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            strip.addArrangedSubview(empty)
        } else {
            for url in photos {
                strip.addArrangedSubview(makePhotoThumbnail(url))
            }
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            openButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            openButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            strip.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            strip.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16),
            strip.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            strip.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14)
        ])
        return row
    }

    private func makePhotoThumbnail(_ url: URL) -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(openPhoto(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(contentsOf: url)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.cornerCurve = .continuous
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 112).isActive = true
        button.heightAnchor.constraint(equalToConstant: 84).isActive = true
        // Stash the path on the control so the click handler knows which file to open.
        button.identifier = NSUserInterfaceItemIdentifier(url.path)
        button.toolTip = "Open \(url.lastPathComponent)"
        return button
    }

    @objc private func openPhoto(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func buildAboutPane() -> NSView {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"

        let versionValue = NSTextField(labelWithString: version)
        versionValue.font = .systemFont(ofSize: 13)
        versionValue.textColor = .secondaryLabelColor

        let resetButton = NSButton(title: "Reset…", target: self, action: #selector(reset))
        resetButton.bezelStyle = .rounded

        let deleteButton = NSButton(title: "Delete SoftLock…", target: self, action: #selector(deleteApp))
        deleteButton.bezelStyle = .rounded
        deleteButton.contentTintColor = .systemRed

        let pane = verticalGroups([
            makeGroup([
                makeRow("Version", control: versionValue),
                makeRow("Reset all settings", control: resetButton)
            ]),
            changelogSection(),
            makeGroup([
                makeRow("Delete passcode & permissions", control: deleteButton)
            ])
        ])
        pane.addArrangedSubview(footnote("Delete SoftLock clears your passcode, settings, and the macOS permission grants (Accessibility, Screen Recording, Camera), then quits — so a reinstall starts clean without stale permissions to remove by hand."))
        pane.addArrangedSubview(footnote("softlock by oguzberkacar — a menu bar lock that keeps local agents running while blocking casual access to your Mac."))
        return pane
    }

    // MARK: - Grouped-row helpers

    private func verticalGroups(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        return stack
    }

    // MARK: macOS 26 (Tahoe) settings styling

    /// Corner radius for grouped "inset" cards, matching macOS 26 System Settings.
    static let cardCornerRadius: CGFloat = 12

    /// Applies the macOS 26 grouped-card look: continuous rounded corners, a soft fill, and a
    /// faint hairline border that gives the card definition over the translucent background.
    private func applyCardStyle(to view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.cardCornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }

    /// A thin inset hairline between rows, lighter than NSBox's separator to match Tahoe.
    private func makeRowSeparator(in stack: NSStackView) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func makeGroup(_ rows: [NSView]) -> NSView {
        let container = NSView()
        applyCardStyle(to: container)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 520).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        for (i, row) in rows.enumerated() {
            if i > 0 {
                let sep = makeRowSeparator(in: stack)
                stack.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
                sep.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeRow(_ label: String, control: NSView?, height: CGFloat = 42) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: height).isActive = true

        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = .labelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lbl.lineBreakMode = .byTruncatingTail
        row.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            NSLayoutConstraint.activate([
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                control.leadingAnchor.constraint(greaterThanOrEqualTo: lbl.trailingAnchor, constant: 12)
            ])
        }
        return row
    }

    /// "What's New" block for the About pane: a heading plus a scrollable card that renders
    /// `Changelog.entries`, so release notes live in one place and show up in Settings.
    private func changelogSection() -> NSView {
        let heading = NSTextField(labelWithString: "What's New")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let entriesStack = NSStackView()
        entriesStack.orientation = .vertical
        entriesStack.alignment = .leading
        entriesStack.spacing = 6
        entriesStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        entriesStack.translatesAutoresizingMaskIntoConstraints = false

        for (index, entry) in Changelog.entries.enumerated() {
            if index > 0 {
                entriesStack.setCustomSpacing(16, after: entriesStack.arrangedSubviews.last!)
            }
            let title = NSTextField(labelWithString: "Version \(entry.version)  ·  \(entry.date)")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = .labelColor
            entriesStack.addArrangedSubview(title)

            for change in entry.changes {
                let bullet = NSTextField(wrappingLabelWithString: "•  \(change)")
                bullet.font = .systemFont(ofSize: 12)
                bullet.textColor = .secondaryLabelColor
                bullet.preferredMaxLayoutWidth = 480
                entriesStack.addArrangedSubview(bullet)
                bullet.widthAnchor.constraint(equalTo: entriesStack.widthAnchor, constant: -28).isActive = true
            }
        }

        // A flipped document keeps the list top-aligned and scrolling from the top; an
        // ordinary NSView document would pin the content to the bottom.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(entriesStack)
        NSLayoutConstraint.activate([
            entriesStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            entriesStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            entriesStack.topAnchor.constraint(equalTo: document.topAnchor),
            entriesStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Mirror the scrollable grid elsewhere in this window: pin the document width to the
        // clip view so the wrapping labels lay out instead of collapsing to zero width.
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let card = NSView()
        applyCardStyle(to: card)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 520),
            card.heightAnchor.constraint(equalToConstant: 180),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        let stack = NSStackView(views: [heading, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.preferredMaxLayoutWidth = 520
        // Pin the width to the cards' so the wrapped height is computed for the real width
        // (an unconstrained wrapping label can be measured at a different width and get
        // clipped or leave a gap).
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return label
    }

    private func passcodeDescription() -> String {
        switch settings.unlockStyle {
        case .pin: return "\(settings.pinLength)-digit PIN"
        case .password: return "Password"
        }
    }

    private func configure(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        if settings.liquidGlassInputsEnabled {
            applySettingsGlassStyle(to: field)
        } else {
            field.isBezeled = true
            field.drawsBackground = true
            field.focusRingType = .default
            field.backgroundColor = .textBackgroundColor
            field.layer?.backgroundColor = nil
            field.layer?.borderWidth = 0
            field.layer?.shadowOpacity = 0
        }
    }

    private func makeBackgroundEffectControl() -> NSView {
        backgroundKindPopup.removeAllItems()
        for kind in BackgroundEffectKind.allCases {
            backgroundKindPopup.addItem(withTitle: kind.title)
            backgroundKindPopup.lastItem?.representedObject = kind.rawValue
        }
        backgroundKindPopup.selectItem(withTitle: settings.backgroundEffectKind.title)
        backgroundKindPopup.target = self
        backgroundKindPopup.action = #selector(backgroundEffectChanged)

        blurSlider.doubleValue = settings.blurLevel
        blurSlider.target = self
        blurSlider.action = #selector(blurChanged)
        blurSlider.translatesAutoresizingMaskIntoConstraints = false
        blurSlider.widthAnchor.constraint(equalToConstant: 154).isActive = true
        blurValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        blurValueLabel.textColor = .secondaryLabelColor
        blurValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        updateBlurLabel()
        let blurControl = NSStackView(views: [label("Blur"), blurSlider, blurValueLabel])
        blurControl.spacing = 8
        blurControl.alignment = .centerY

        buildBackgroundColorSwatches()
        let colorControl = NSStackView(views: [label("Color"), backgroundColorStack])
        colorControl.spacing = 8
        colorControl.alignment = .centerY

        backgroundMediaButton.target = self
        backgroundMediaButton.action = #selector(chooseBackgroundMedia)
        backgroundMediaButton.bezelStyle = .rounded
        appleWallpapersButton.target = self
        appleWallpapersButton.action = #selector(chooseAppleWallpaper)
        appleWallpapersButton.bezelStyle = .rounded
        appleWallpapersButton.toolTip = "Choose from macOS desktop pictures and wallpaper videos"
        backgroundMediaClearButton.target = self
        backgroundMediaClearButton.action = #selector(clearBackgroundMedia)
        backgroundMediaClearButton.bezelStyle = .rounded
        backgroundMediaLabel.font = .systemFont(ofSize: 12)
        backgroundMediaLabel.textColor = .secondaryLabelColor
        backgroundMediaLabel.lineBreakMode = .byTruncatingMiddle
        backgroundMediaLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let mediaControl = NSStackView(views: [
            label("Media"),
            backgroundMediaLabel,
            backgroundMediaButton,
            appleWallpapersButton,
            backgroundMediaClearButton
        ])
        mediaControl.spacing = 8
        mediaControl.alignment = .centerY

        let stack = NSStackView(views: [backgroundKindPopup, blurControl, colorControl, mediaControl])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        updateBackgroundControls()
        return stack
    }

    private func makeInputAppearanceControl() -> NSView {
        inputAppearancePopup.removeAllItems()
        for mode in InputAppearanceMode.allCases {
            inputAppearancePopup.addItem(withTitle: mode.title)
            inputAppearancePopup.lastItem?.representedObject = mode.rawValue
        }
        inputAppearancePopup.selectItem(withTitle: settings.inputAppearanceMode.title)
        inputAppearancePopup.target = self
        inputAppearancePopup.action = #selector(inputAppearanceChanged)
        return inputAppearancePopup
    }

    private func makeLiquidGlassInputsControl() -> NSView {
        liquidGlassInputsSwitch.state = settings.liquidGlassInputsEnabled ? .on : .off
        liquidGlassInputsSwitch.target = self
        liquidGlassInputsSwitch.action = #selector(liquidGlassInputsChanged)
        return liquidGlassInputsSwitch
    }

    private func applySettingsGlassStyle(to field: NSTextField) {
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.layer?.cornerCurve = .continuous
        field.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.46).cgColor
        field.layer?.borderWidth = 0.8
        field.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        field.layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        field.layer?.shadowOpacity = 1
        field.layer?.shadowRadius = 12
        // Layer space is y-up, so a negative height drops the shadow below the field.
        field.layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    private func label(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 42).isActive = true
        return label
    }

    private func buildBackgroundColorSwatches() {
        backgroundColorStack.arrangedSubviews.forEach {
            backgroundColorStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        backgroundColorButtons = []
        backgroundColorStack.orientation = .horizontal
        backgroundColorStack.spacing = 6
        backgroundColorStack.alignment = .centerY

        for (index, swatch) in LockBackgroundSwatch.all.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(backgroundColorPicked(_:)))
            button.tag = index
            button.isBordered = false
            button.toolTip = swatch.title
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.cornerCurve = .continuous
            button.layer?.backgroundColor = swatch.color.cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            backgroundColorButtons.append(button)
            backgroundColorStack.addArrangedSubview(button)
        }
        updateBackgroundColorSwatches()
    }

    private func updateBackgroundControls() {
        let kind = settings.backgroundEffectKind
        blurSlider.isEnabled = kind == .blur
        blurValueLabel.textColor = kind == .blur ? .secondaryLabelColor : .tertiaryLabelColor
        backgroundColorButtons.forEach { $0.isEnabled = kind == .color }
        backgroundMediaButton.isEnabled = kind == .media
        appleWallpapersButton.isEnabled = kind == .media
        backgroundMediaClearButton.isEnabled = kind == .media && settings.backgroundMediaURL != nil
        backgroundMediaLabel.stringValue = settings.backgroundMediaDisplayName
        backgroundMediaLabel.textColor = kind == .media ? .secondaryLabelColor : .tertiaryLabelColor
        updateBackgroundColorSwatches()
    }

    private func updateBackgroundColorSwatches() {
        for (index, button) in backgroundColorButtons.enumerated() {
            let selected = LockBackgroundSwatch.all[index].id == settings.backgroundColorID
            button.layer?.borderWidth = selected ? 2 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        }
    }

    private func makeLaunchAtLoginControl() -> NSView {
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged)

        launchAtLoginStatusLabel.font = .systemFont(ofSize: 12)
        launchAtLoginStatusLabel.alignment = .right
        launchAtLoginStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 155).isActive = true

        launchAtLoginSettingsButton.target = self
        launchAtLoginSettingsButton.action = #selector(openLoginItemsSettings)
        launchAtLoginSettingsButton.bezelStyle = .rounded

        let control = NSStackView(views: [launchAtLoginSwitch, launchAtLoginStatusLabel, launchAtLoginSettingsButton])
        control.spacing = 8
        updateLaunchAtLoginControls()
        return control
    }

    // MARK: - Live apply

    @objc private func lockTapped() {
        window.close()
        onLock()
    }

    @objc private func changePasscodeTapped() {
        window.close()
        onChangePasscode()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        applyTitle()
    }

    private func applyTitle() {
        settings.lockTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func blurChanged() {
        updateBlurLabel()
        settings.blurLevel = blurSlider.doubleValue
    }

    @objc private func backgroundEffectChanged() {
        let rawValue = backgroundKindPopup.selectedItem?.representedObject as? String
        settings.backgroundEffectKind = BackgroundEffectKind(rawValue: rawValue ?? "") ?? .blur
        updateBackgroundControls()
    }

    @objc private func backgroundColorPicked(_ sender: NSButton) {
        guard LockBackgroundSwatch.all.indices.contains(sender.tag) else { return }
        settings.backgroundColorID = LockBackgroundSwatch.all[sender.tag].id
        settings.backgroundEffectKind = .color
        backgroundKindPopup.selectItem(withTitle: BackgroundEffectKind.color.title)
        updateBackgroundControls()
    }

    @objc private func chooseBackgroundMedia() {
        openBackgroundMediaPanel(startingAt: nil, showsHiddenFiles: false)
    }

    @objc private func chooseAppleWallpaper() {
        let assets = SystemWallpaperLibrary.assets()
        guard !assets.isEmpty else {
            openBackgroundMediaPanel(
                startingAt: URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
                showsHiddenFiles: true
            )
            return
        }

        let picker = WallpaperPickerWindowController(assets: assets) { [weak self] asset in
            self?.importBackgroundMedia(from: asset.sourceURL)
        }
        wallpaperPicker = picker
        window.beginSheet(picker.window) { [weak self] _ in
            self?.wallpaperPicker = nil
        }
    }

    private func openBackgroundMediaPanel(startingAt directoryURL: URL?, showsHiddenFiles: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.image, .movie]
        if let madeDesktopType = UTType(filenameExtension: "madesktop") {
            contentTypes.append(madeDesktopType)
        }
        panel.allowedContentTypes = contentTypes
        panel.directoryURL = directoryURL
        panel.showsHiddenFiles = showsHiddenFiles
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importBackgroundMedia(from: url)
        }
    }

    private func importBackgroundMedia(from url: URL) {
        Task { @MainActor in
            do {
                try settings.storeBackgroundMedia(from: url)
                settings.backgroundEffectKind = .media
                backgroundKindPopup.selectItem(withTitle: BackgroundEffectKind.media.title)
                updateBackgroundControls()
            } catch {
                backgroundMediaLabel.stringValue = "Couldn't load"
                AppLog.write("background media import failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func clearBackgroundMedia() {
        settings.clearBackgroundMedia()
        updateBackgroundControls()
    }

    @objc private func inputAppearanceChanged() {
        let rawValue = inputAppearancePopup.selectedItem?.representedObject as? String
        settings.inputAppearanceMode = InputAppearanceMode(rawValue: rawValue ?? "") ?? .auto
    }

    @objc private func liquidGlassInputsChanged() {
        settings.liquidGlassInputsEnabled = liquidGlassInputsSwitch.state == .on
        selectPane(selectedIndex)
    }

    @objc private func touchIDChanged() {
        settings.useTouchID = touchIDSwitch.state == .on
    }

    @objc private func captureChanged() {
        settings.capturePhotoOnFailure = captureSwitch.state == .on
        updatePermissionsLabel()
    }

    @objc private func maxPhotosChanged() {
        updateMaxPhotosLabel()
        settings.maxFailedAttemptPhotos = maxPhotosStepper.integerValue
    }

    func windowWillClose(_ notification: Notification) {
        applyTitle()
    }

    private func updateBlurLabel() {
        blurValueLabel.stringValue = "\(Int((blurSlider.doubleValue * 100).rounded()))%"
    }

    private func updateMaxPhotosLabel() {
        maxPhotosLabel.stringValue = "\(maxPhotosStepper.integerValue) photos"
    }

    private func updateLaunchAtLoginControls() {
        let status = settings.launchAtLoginStatus
        launchAtLoginSwitch.isEnabled = status != .notFound
        launchAtLoginSettingsButton.isHidden = status != .requiresApproval && status != .notFound

        switch status {
        case .enabled:
            launchAtLoginSwitch.state = .on
            launchAtLoginStatusLabel.stringValue = "Enabled"
            launchAtLoginStatusLabel.textColor = .systemGreen
            launchAtLoginSettingsButton.title = "Open Settings..."
            launchAtLoginSettingsButton.action = #selector(openLoginItemsSettings)
        case .notRegistered:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatusLabel.stringValue = launchAtLoginError ?? "Off"
            launchAtLoginStatusLabel.textColor = launchAtLoginError == nil ? .secondaryLabelColor : .systemRed
            launchAtLoginSettingsButton.title = "Open Settings..."
            launchAtLoginSettingsButton.action = #selector(openLoginItemsSettings)
        case .requiresApproval:
            launchAtLoginSwitch.state = .on
            launchAtLoginStatusLabel.stringValue = "Needs approval"
            launchAtLoginStatusLabel.textColor = .systemOrange
            launchAtLoginSettingsButton.title = "Open Settings..."
            launchAtLoginSettingsButton.action = #selector(openLoginItemsSettings)
        case .notFound:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatusLabel.stringValue = launchAtLoginError ?? settings.launchAtLoginUnavailableReason
            launchAtLoginStatusLabel.textColor = .systemRed
            launchAtLoginSettingsButton.title = "Reveal App"
            launchAtLoginSettingsButton.action = #selector(revealCurrentApp)
        @unknown default:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatusLabel.stringValue = "Unknown"
            launchAtLoginStatusLabel.textColor = .systemRed
            launchAtLoginSettingsButton.title = "Open Settings..."
            launchAtLoginSettingsButton.action = #selector(openLoginItemsSettings)
        }
    }

    @objc private func launchAtLoginChanged() {
        launchAtLoginError = nil
        do {
            try settings.setLaunchAtLoginEnabled(launchAtLoginSwitch.state == .on)
        } catch {
            launchAtLoginError = "Couldn't update"
            AppLog.write("launch at login update failed: \(error.localizedDescription)")
        }
        updateLaunchAtLoginControls()
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        updateLaunchAtLoginControls()
    }

    @objc private func revealCurrentApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func checkPermissions() {
        let cameraRequired = captureSwitch.state == .on
        if cameraRequired, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updatePermissionsLabel()
                }
            }
            return
        }

        if !AXIsProcessTrusted() {
            let promptKey = "AXTrustedCheckOptionPrompt" as NSString
            AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }

        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        updatePermissionsLabel()
    }

    private func updatePermissionsLabel() {
        let statuses = currentPermissionStatuses()

        permissionsStack.arrangedSubviews.forEach {
            permissionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for status in statuses {
            permissionsStack.addArrangedSubview(makePermissionRow(status))
        }
    }

    /// One line per permission, stacked vertically so they never get truncated the way
    /// the old single side-by-side line did. Green check when ready, red cross plus a Grant
    /// button when a needed permission is missing. A permission that isn't needed in the
    /// current configuration shows a muted "Not needed" instead of a red warning.
    private func makePermissionRow(_ status: PermissionStatus) -> NSView {
        let symbolName: String
        let tint: NSColor
        if status.ok {
            symbolName = status.required ? "checkmark.circle.fill" : "minus.circle.fill"
            tint = status.required ? .systemGreen : .tertiaryLabelColor
        } else {
            symbolName = "xmark.circle.fill"
            tint = .systemRed
        }

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = tint

        let label = NSTextField(labelWithString: status.ok && !status.required ? "\(status.name) (not needed)" : status.name)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = tint

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY

        if !status.ok {
            let grant = NSButton(title: "Grant", target: self, action: #selector(grantPermission(_:)))
            grant.bezelStyle = .inline
            grant.controlSize = .small
            grant.font = .systemFont(ofSize: 11, weight: .semibold)
            grant.tag = permissionTag(status.kind)
            row.addArrangedSubview(grant)
        }

        row.toolTip = status.ok ? "\(status.name): \(status.required ? "Ready" : "Not needed")" : "\(status.name): \(status.detail)"
        return row
    }

    private func permissionTag(_ kind: PermissionKind) -> Int {
        switch kind {
        case .accessibility: return 0
        case .screenRecording: return 1
        case .camera: return 2
        }
    }

    @objc private func grantPermission(_ sender: NSButton) {
        let kind: PermissionKind = sender.tag == 0 ? .accessibility : (sender.tag == 1 ? .screenRecording : .camera)
        switch kind {
        case .accessibility:
            let promptKey = "AXTrustedCheckOptionPrompt" as NSString
            AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            openPrivacyPane(kind)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            openPrivacyPane(kind)
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    DispatchQueue.main.async { self?.updatePermissionsLabel() }
                }
            } else {
                openPrivacyPane(kind)
            }
        }
        updatePermissionsLabel()
    }

    private func openPrivacyPane(_ kind: PermissionKind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.privacyAnchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func currentPermissionStatuses() -> [PermissionStatus] {
        // Screen Recording is only used to sample the desktop for Auto input appearance over a
        // see-through background — mirror exactly that condition (see sampleScreenBrightness).
        let screenRecordingRequired = settings.inputAppearanceMode == .auto
            && (settings.backgroundEffectKind == .transparent || settings.backgroundEffectKind == .blur)

        let cameraRequired = captureSwitch.state == .on
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        return [
            PermissionStatus(
                name: "Accessibility",
                kind: .accessibility,
                ok: AXIsProcessTrusted(),
                required: true,
                detail: "needed for keyboard/mouse lock protection"
            ),
            PermissionStatus(
                name: "Screen Recording",
                kind: .screenRecording,
                ok: !screenRecordingRequired || CGPreflightScreenCaptureAccess(),
                required: screenRecordingRequired,
                detail: "needed for Auto input appearance over transparent/blur backgrounds"
            ),
            PermissionStatus(
                name: "Camera",
                kind: .camera,
                ok: !cameraRequired || cameraStatus == .authorized,
                required: cameraRequired,
                detail: cameraRequired ? cameraStatus.permissionDetail : "optional unless failed-attempt photos are enabled"
            )
        ]
    }

    @objc private func reset() {
        settings.lockTitle = AppSettings.defaultLockTitle
        settings.backgroundEffectKind = .blur
        settings.blurLevel = AppSettings.defaultBlurLevel
        settings.backgroundColorID = LockBackgroundSwatch.defaultID
        settings.clearBackgroundMedia()
        settings.inputAppearanceMode = .auto
        settings.liquidGlassInputsEnabled = false
        settings.lockShortcuts = [AppSettings.defaultShortcut]
        settings.useTouchID = BiometricAuth.isAvailable
        settings.capturePhotoOnFailure = false
        settings.maxFailedAttemptPhotos = AppSettings.defaultMaxFailedAttemptPhotos
        FaceUnlockSettings.shared.isEnabled = false
        selectPane(selectedIndex)
    }

    @objc private func deleteApp() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete SoftLock?"
        alert.informativeText = "This erases your passcode and settings and revokes SoftLock's macOS permissions (Accessibility, Screen Recording, Camera). SoftLock will quit. You can re-grant permissions next time you launch it.\n\nThis can't be undone."
        alert.addButton(withTitle: "Delete & Quit")
        alert.addButton(withTitle: "Cancel")

        if let cancel = alert.buttons.last {
            alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        window.close()
        onDeleteApp()
    }

    @objc private func openFailedAttempts() {
        do {
            let directoryURL = try FailedAttemptStore.directory()
            NSWorkspace.shared.open(directoryURL)
        } catch {
            AppLog.write("failed attempts folder open failed: \(error.localizedDescription)")
        }
    }
}
@MainActor
private final class SetupWindowController: NSObject {
    private let store: PasswordStore
    private let settings: AppSettings
    private let onSaved: (String) -> Void
    private let window: NSWindow

    private let passwordField = NSSecureTextField()
    private let confirmField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let instructionLabel = NSTextField(labelWithString: "")
    private var pinView: PINInputView?

    // 0 = password, 1 = 4-digit PIN, 2 = 6-digit PIN
    private var styleIndex: Int
    private var firstPIN: String?

    init(store: PasswordStore, settings: AppSettings = .shared, onSaved: @escaping (String) -> Void) {
        self.store = store
        self.settings = settings
        self.onSaved = onSaved
        if settings.unlockStyle == .pin {
            styleIndex = settings.pinLength == 6 ? 2 : 1
        } else {
            styleIndex = 0
        }
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        rebuild()
    }

    func show() {
        window.level = .floating
        window.centerOnActiveScreen()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        focusInput()
        AppLog.write("setup window shown frame=\(window.frame)")
    }

    /// Make the active input the first responder so digits/keys go straight to it without
    /// needing a mouse click — the PIN pad in particular was mouse-only before.
    private func focusInput() {
        if let pinView {
            window.makeFirstResponder(pinView)
        } else {
            window.makeFirstResponder(passwordField)
        }
    }

    func close() {
        window.close()
    }

    private var isPIN: Bool { styleIndex != 0 }
    private var pinLength: Int { styleIndex == 2 ? 6 : 4 }

    @objc private func styleChanged(_ sender: NSSegmentedControl) {
        styleIndex = sender.selectedSegment
        firstPIN = nil
        statusLabel.stringValue = ""
        rebuild()
    }

    private func rebuild() {
        let setup = !store.isConfigured
        window.title = setup ? "Set Up SoftLock" : "Change Passcode"

        // Window height is derived from the laid-out content below (not hard-coded), so a
        // longer note/error message can't overflow the panel and force AppKit to break
        // constraints.
        let contentWidth: CGFloat = 420
        let panelInset: CGFloat = 18
        let stackInset: CGFloat = 22
        let stackWidth = contentWidth - 2 * (panelInset + stackInset)
        let previousTop = window.frame.maxY

        let root = makeWindowBackgroundView()
        let panel = makeGlassPanel()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: window.title)
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let selector = NSSegmentedControl(
            labels: ["Password", "4-digit PIN", "6-digit PIN"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(styleChanged(_:))
        )
        selector.selectedSegment = styleIndex
        selector.segmentStyle = .rounded

        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = stackWidth

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(selector)

        if isPIN {
            instructionLabel.stringValue = firstPIN == nil ? "Enter a \(pinLength)-digit PIN" : "Re-enter your PIN"
            instructionLabel.font = .systemFont(ofSize: 14, weight: .medium)
            instructionLabel.alignment = .center

            let pinView = PINInputView(length: pinLength, onDark: false) { [weak self] pin in
                self?.handlePINEntry(pin)
            }
            self.pinView = pinView
            stack.setCustomSpacing(20, after: selector)
            stack.addArrangedSubview(instructionLabel)
            stack.addArrangedSubview(pinView)
            stack.addArrangedSubview(statusLabel)
        } else {
            pinView = nil
            let note = NSTextField(wrappingLabelWithString: "SoftLock runs from the menu bar. Locking the screen never pauses your background processes — unlocking just needs your password or recovery code.")
            note.textColor = .secondaryLabelColor
            note.font = .systemFont(ofSize: 13)
            note.alignment = .center
            note.preferredMaxLayoutWidth = stackWidth

            configure(passwordField, placeholder: "Password")
            configure(confirmField, placeholder: "Confirm password")
            passwordField.stringValue = ""
            confirmField.stringValue = ""
            confirmField.target = self
            confirmField.action = #selector(savePassword)
            // Tab moves Password -> Confirm (and back); Return on either saves.
            passwordField.nextKeyView = confirmField
            confirmField.nextKeyView = passwordField

            let saveButton = NSButton(title: "Save Password", target: self, action: #selector(savePassword))
            saveButton.bezelStyle = .rounded
            saveButton.controlSize = .large
            saveButton.keyEquivalent = "\r"

            stack.addArrangedSubview(note)
            stack.addArrangedSubview(passwordField)
            stack.addArrangedSubview(confirmField)
            stack.addArrangedSubview(statusLabel)
            stack.addArrangedSubview(saveButton)

            NSLayoutConstraint.activate([
                passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor),
                confirmField.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }

        panel.addSubview(stack)
        root.addSubview(panel)
        window.contentView = root
        window.initialFirstResponder = isPIN ? pinView : passwordField

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: panelInset),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -panelInset),
            panel.topAnchor.constraint(equalTo: root.topAnchor, constant: panelInset),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -panelInset),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: stackInset),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -stackInset),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: stackInset),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -stackInset),
            stack.widthAnchor.constraint(equalToConstant: stackWidth)
        ])

        // Size the window to the content. The width is fixed, so the stack's fitting height
        // already accounts for wrapped labels.
        let fittingHeight = stack.fittingSize.height + 2 * (panelInset + stackInset)
        window.setContentSize(NSSize(width: contentWidth, height: ceil(fittingHeight)))

        // After a live rebuild (e.g. switching to PIN) keep the window's top edge where it was
        // — a PIN entry phase change must not make the window hop to another spot/screen —
        // and move keyboard focus to the new input.
        if window.isVisible {
            var origin = window.frame.origin
            origin.y = previousTop - window.frame.height
            window.setFrameOrigin(origin)
            focusInput()
        }
    }

    private func configure(_ field: NSSecureTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 16)
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
    }

    private func handlePINEntry(_ pin: String) {
        guard let first = firstPIN else {
            firstPIN = pin
            instructionLabel.stringValue = "Re-enter your PIN"
            statusLabel.stringValue = ""
            refreshPINView()
            return
        }

        guard pin == first else {
            firstPIN = nil
            instructionLabel.stringValue = "Enter a \(pinLength)-digit PIN"
            statusLabel.stringValue = "Those PINs didn't match. Try again."
            refreshPINView()
            return
        }

        commit(credential: pin, style: .pin, pinLength: pinLength)
    }

    /// Rebuild just to reset the PIN dots between phases.
    private func refreshPINView() {
        rebuild()
    }

    @objc private func savePassword() {
        let password = passwordField.stringValue
        let confirm = confirmField.stringValue

        guard password.count >= 4 else {
            statusLabel.stringValue = "Password must be at least 4 characters."
            return
        }

        guard password == confirm else {
            statusLabel.stringValue = "Passwords don't match."
            return
        }

        commit(credential: password, style: .password, pinLength: 4)
    }

    private func commit(credential: String, style: UnlockStyle, pinLength: Int) {
        do {
            let recoveryCode = try store.save(password: credential)
            settings.unlockStyle = style
            settings.pinLength = pinLength
            close()
            onSaved(recoveryCode)
        } catch {
            statusLabel.stringValue = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

@MainActor
private final class LockerController: NSObject {
    private let store: PasswordStore
    private let settings: AppSettings
    private let onUnlock: (Bool) -> Void
    private var windows: [LockWindow] = []
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var passwordField: NSSecureTextField?
    private var statusLabel: LockStatusView?
    private var faceSelfView: LockFaceSelfView?
    private var faceSession: AVCaptureSession?
    private var faceViewState: FaceUnlockViewState = .scanning
    private var touchIDButton: NSButton?
    private var faceScanButton: NSButton?
    private var faceScanKeyMonitor: Any?
    private var pinInputView: PINInputView?
    private var pinRecoveryField: NSSecureTextField?
    private var pinRecoveryContainer: NSView?
    private var biometricInProgress = false
    private var failedAttempts = 0
    private var lockoutTimer: Timer?
    private var lockoutRemaining = 0
    private let credentialErrorText = "Incorrect — try again."
    private var clockLabels: [(time: NSTextField, date: NSTextField)] = []
    private var clockTimer: Timer?
    private var hotKeyInputGate: HotKeyInputGate?
    private var hotKeyInputGateTimer: Timer?
    private var hotKeyInputGatePollTimer: Timer?
    private var observesDisplayChanges = false
    private var primaryDisplayID: UInt32?

    private struct HotKeyInputGate {
        let keyCode: Int
        let requiredFlags: CGEventFlags
        var keyReleased = false
        var modifiersReleased = false

        var isComplete: Bool {
            keyReleased && modifiersReleased
        }
    }

    init(store: PasswordStore, settings: AppSettings, onUnlock: @escaping (Bool) -> Void) {
        self.store = store
        self.settings = settings
        self.onUnlock = onUnlock
        super.init()
    }

    func lock(trigger: LockTrigger) {
        requestAccessibilityIfNeeded()
        startObservingDisplayChanges()
        // Before rebuilding: a previous face unlock leaves the green ring and tick behind, and a
        // stopped capture session in `faceSession`. A fresh lock screen must not adopt either.
        faceSession = nil
        faceViewState = .scanning
        // Rebuild every time so the current blur/title/passcode settings always apply.
        rebuildWindows()
        failedAttempts = 0
        lockoutTimer?.invalidate()
        lockoutTimer = nil
        resetCredentialInput()
        statusLabel?.show("")
        configureInitialInputState(for: trigger)
        installEventTap()
        startClock()
        activateLock()
        installFaceScanKeyMonitor()
        startFaceUnlockIfNeeded()
    }

    /// Optional face unlock (off by default). Adds a way in next to the passcode and Touch ID; never
    /// replaces them. See FaceUnlockController.
    private func startFaceUnlockIfNeeded() {
        faceSession = nil
        faceViewState = .scanning
        guard FaceUnlockSettings.shared.isReadyForLockScreen else { return }
        guard FaceUnlockSettings.shared.autoScanOnLock else {
            // Manual mode: nothing looks at the camera until the button or Space asks it to.
            updateFaceScanButton()
            showStatus(Self.faceScanHint, tone: .info)
            return
        }
        beginFaceScan()
    }

    /// Starts one face scan cycle. Manual trigger (camera button / Space) and the automatic
    /// start on lock both come through here.
    private func beginFaceScan() {
        guard FaceUnlockSettings.shared.isReadyForLockScreen else { return }
        // Face unlock respects the brute-force lockout exactly like Touch ID does.
        guard lockoutTimer == nil, !windows.isEmpty else { return }
        guard !FaceUnlockController.shared.isScanning else { return }
        let missPhoto: ((FaceCameraFrame) -> Void)? = settings.capturePhotoOnFailure
            ? { [weak self] frame in self?.saveFaceMissPhoto(frame) }
            : nil
        FaceUnlockController.shared.begin(
            onEvent: { [weak self] event in self?.handleFaceEvent(event) },
            onMissFrame: missPhoto,
            onUnlock: { [weak self] in
                // Respect the brute-force lockout exactly like Touch ID does.
                guard let self, self.lockoutTimer == nil, !self.windows.isEmpty else { return false }
                self.unlock(recoveryUsed: false)
                return true
            }
        )
        updateFaceScanButton()
    }

    private func handleFaceEvent(_ event: FaceUnlockEvent) {
        switch event {
        case .status(let text, let tone):
            showStatus(text, tone: tone)
        case .cameraReady(let session):
            faceSession = session
            faceSelfView?.attachPreview(session: session)
        case .state(let state):
            faceViewState = state
            faceSelfView?.setState(state)
        case .ended:
            faceSession = nil
            faceSelfView?.detach()
            updateFaceScanButton()
        }
    }

    /// A face was present but not recognized: keep the frame the scan already had as a
    /// failed-attempt photo (same folder and photo limit as wrong-passcode captures) instead of
    /// opening a second capture session.
    private func saveFaceMissPhoto(_ frame: FaceCameraFrame) {
        let maxPhotos = settings.maxFailedAttemptPhotos
        Task.detached(priority: .utility) {
            guard let data = FaceCameraFeed.jpegData(from: frame) else { return }
            await MainActor.run { FailedAttemptCamera.shared.saveExternalPhoto(data, maxPhotos: maxPhotos) }
        }
    }

    private func requestAccessibilityIfNeeded() {
        AppLog.write("AX trusted before request: \(AXIsProcessTrusted())")
        guard !AXIsProcessTrusted() else { return }
        let promptKey = "AXTrustedCheckOptionPrompt" as NSString
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private func rebuildWindows() {
        let oldWindows = windows
        windows = []
        clockLabels = []
        passwordField = nil
        pinInputView = nil
        pinRecoveryField = nil
        pinRecoveryContainer = nil
        touchIDButton = nil
        faceScanButton = nil
        statusLabel = nil
        faceSelfView = nil
        buildWindows()
        oldWindows.forEach { $0.orderOut(nil) }
    }

    private func buildWindows() {
        let screens = NSScreen.screens
        // `NSScreen.main` is the screen with keyboard focus, and it is nil when no window is
        // key. Falling back keeps exactly one window hosting the credential input — with a
        // nil main screen every window would be built as secondary, putting up a lock screen
        // with no way to type a passcode at all.
        let primary = NSScreen.main ?? screens.first
        primaryDisplayID = primary?.directDisplayID
        windows = screens.map { makeLockWindow(on: $0, primary: $0 == primary) }
    }

    /// Displays added *after* the lock is up are always secondary: a change of primary
    /// display is detected earlier in `reconcileDisplayWindows` and forces a full rebuild.
    private func makeLockWindow(on screen: NSScreen, primary: Bool = false) -> LockWindow {
        let window = LockWindow(screen: screen)
        window.builtCompact = Self.isCompact(screen)
        window.contentView = makeContentView(on: screen, primary: primary)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    fileprivate static func isCompact(_ screen: NSScreen) -> Bool {
        screen.frame.height < 950
    }

    private func startObservingDisplayChanges() {
        guard !observesDisplayChanges else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        observesDisplayChanges = true
    }

    private func stopObservingDisplayChanges() {
        guard observesDisplayChanges else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        observesDisplayChanges = false
    }

    @objc private func displayParametersDidChange(_ notification: Notification) {
        reconcileDisplayWindows()
    }

    private func reconcileDisplayWindows() {
        guard observesDisplayChanges else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            AppLog.write("display reconciliation deferred: NSScreen.screens is empty")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.reconcileDisplayWindows()
            }
            return
        }

        let screenPairs = screens.compactMap { screen in
            screen.directDisplayID.map { ($0, screen) }
        }
        let windowPairs = windows.compactMap { window in
            window.displayID.map { ($0, window) }
        }

        guard screenPairs.count == screens.count,
              windowPairs.count == windows.count,
              Set(screenPairs.map(\.0)).count == screenPairs.count,
              Set(windowPairs.map(\.0)).count == windowPairs.count
        else {
            AppLog.write("display reconciliation fallback: invalid display identifiers")
            rebuildWindows()
            restoreInputStateAfterRebuild()
            activateLock()
            return
        }

        let screensByID = Dictionary(uniqueKeysWithValues: screenPairs)
        let windowsByID = Dictionary(uniqueKeysWithValues: windowPairs)
        let currentPrimaryDisplayID = NSScreen.main?.directDisplayID

        guard currentPrimaryDisplayID == primaryDisplayID else {
            AppLog.write("primary display changed; rebuilding lock windows")
            rebuildWindows()
            restoreInputStateAfterRebuild()
            activateLock()
            return
        }

        let delta = DisplayTopology.delta(
            existing: Set(windowsByID.keys),
            current: Set(screensByID.keys)
        )

        for id in delta.added {
            guard let screen = screensByID[id] else { continue }
            windows.append(makeLockWindow(on: screen))
            AppLog.write("covered newly connected display: \(id)")
        }

        var needsRelayout = false
        for id in delta.retained {
            guard let screen = screensByID[id], let window = windowsByID[id] else { continue }
            window.setFrame(screen.frame, display: true)
            // The layout metrics (font sizes, keypad size, offsets) are chosen from the display
            // height at build time, so a resolution change that crosses the threshold needs a
            // fresh layout rather than just a resized window.
            if window.builtCompact != Self.isCompact(screen) {
                needsRelayout = true
            }
        }

        if needsRelayout {
            AppLog.write("display resolution class changed; rebuilding lock windows")
            rebuildWindows()
            restoreInputStateAfterRebuild()
            activateLock()
            return
        }

        for id in delta.removed {
            windowsByID[id]?.orderOut(nil)
        }
        windows.removeAll { window in
            window.displayID.map(delta.removed.contains) ?? true
        }

        maintainLockPresentation(refocusInput: true)
    }

    /// Re-apply the transient input state after the lock windows are rebuilt. A rebuilt
    /// window comes up with a fresh, enabled, empty input — so without this, hot-plugging a
    /// display during a brute-force lockout (or during the hot-key release gate) hands back
    /// an unthrottled prompt.
    private func restoreInputStateAfterRebuild() {
        if lockoutTimer != nil {
            setInputEnabled(false)
            showStatus("Too many attempts. Try again in \(lockoutRemaining)s.")
            return
        }

        setInputEnabled(hotKeyInputGate == nil)
    }

    private func makeContentView(on screen: NSScreen, primary: Bool) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        // Small laptop displays don't have room for the full-size clock + badge + keypad
        // stack, so below this height we scale the whole lock layout down a notch.
        let compact = Self.isCompact(screen)

        installLockBackground(in: root)
        let screenBrightness = primary ? sampleScreenBrightness(on: screen) : nil
        let appearance = settings.resolvedInputAppearance(screenBrightness: screenBrightness)
        let glassInputsEnabled = settings.liquidGlassInputsEnabled

        // Clock at the top of every display, like the macOS lock screen.
        let clock = makeClockBlock(appearance: appearance, compact: compact)
        root.addSubview(clock.stack)
        NSLayoutConstraint.activate([
            clock.stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            clock.stack.topAnchor.constraint(equalTo: root.topAnchor, constant: compact ? 64 : 110)
        ])
        clockLabels.append((clock.time, clock.date))

        guard primary else { return root }

        let usePIN = settings.unlockStyle == .pin

        let badgeDiameter: CGFloat = 76
        // With face unlock ready the badge *is* the camera button: it already occupies the spot
        // the self-view takes over during a scan, so the scan starts where the camera appears.
        let faceReady = FaceUnlockSettings.shared.isReadyForLockScreen
        let badge = makeLockBadge(
            appearance: appearance,
            diameter: badgeDiameter,
            symbolName: faceReady ? "faceid" : "lock.fill",
            symbolDescription: faceReady ? "Scan your face" : "Locked"
        )

        let title = NSTextField(labelWithString: settings.displayTitle)
        title.font = .systemFont(ofSize: compact ? 22 : 26, weight: .semibold)
        title.textColor = appearance.primaryText
        title.alignment = .center
        title.shadow = appearance.textShadow

        let subtitle = NSTextField(labelWithString: usePIN ? "Enter your passcode to unlock" : "Enter your password to unlock")
        subtitle.font = .systemFont(ofSize: compact ? 13 : 14, weight: .regular)
        subtitle.textColor = appearance.secondaryText
        subtitle.alignment = .center
        subtitle.shadow = appearance.textShadow

        // Fixed 320 x 44 holder: the pill inside sizes to its text, so an error message
        // appearing, growing or wrapping never resizes the stack that is centred on screen
        // (that made the whole lock layout twitch on every wrong PIN).
        let status = LockStatusView()

        // For PIN unlock the Touch ID button lives inside the keypad (the empty cell next to
        // 0), so it shares the keypad's size and frees the vertical space a separate row took.
        let touchIDAvailable = settings.useTouchID && BiometricAuth.isAvailable

        let inputView: NSView
        if usePIN {
            let pinView = PINInputView(
                length: settings.pinLength,
                onDark: appearance.usesLightContent,
                glassEnabled: glassInputsEnabled,
                compact: compact,
                onTouchID: touchIDAvailable ? { [weak self] in self?.attemptBiometricUnlock(automatic: false) } : nil
            ) { [weak self] pin in
                self?.verifyCredential(pin)
            }
            pinInputView = pinView

            let (recoveryField, recoveryContainer) = makeLockInput(
                placeholder: "Recovery code",
                action: #selector(submitRecoveryField),
                appearance: appearance,
                glassEnabled: glassInputsEnabled
            )
            recoveryContainer.isHidden = true
            pinRecoveryField = recoveryField
            pinRecoveryContainer = recoveryContainer

            // The keypad and the recovery field swap in place. They share a fixed-size holder
            // (height taken from the keypad) so toggling "Forgot PIN?" doesn't change the
            // height of the centred lock stack and shove the badge/title around.
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(pinView)
            container.addSubview(recoveryContainer)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 320),
                container.heightAnchor.constraint(equalTo: pinView.heightAnchor),
                pinView.topAnchor.constraint(equalTo: container.topAnchor),
                pinView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                recoveryContainer.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                recoveryContainer.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            inputView = container
        } else {
            let (field, container) = makeLockInput(
                placeholder: "Password or recovery code",
                action: #selector(submitCredential),
                appearance: appearance,
                glassEnabled: glassInputsEnabled
            )
            passwordField = field
            inputView = container
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(badge)
        stack.setCustomSpacing(compact ? 12 : 18, after: badge)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(compact ? (usePIN ? 18 : 14) : (usePIN ? 26 : 18), after: subtitle)
        stack.addArrangedSubview(inputView)
        // The status pill is not part of the centred stack: it sits at the bottom of the screen
        // like a toast, so a message appearing or growing never shifts the lock layout and it
        // reads as feedback rather than as another row of the form.
        root.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: compact ? -28 : -44)
        ])

        // Password unlock has no keypad to host Touch ID, so it keeps the standalone icon
        // button. PIN unlock places Touch ID inside the keypad instead (see above).
        if touchIDAvailable, !usePIN {
            let button = makeTouchIDButton(appearance: appearance)
            stack.setCustomSpacing(8, after: inputView)
            stack.addArrangedSubview(button)
            touchIDButton = button
        }

        if usePIN {
            let forgot = NSButton(title: "Forgot PIN?", target: self, action: #selector(toggleRecoveryEntry))
            forgot.isBordered = false
            forgot.font = .systemFont(ofSize: 12, weight: .medium)
            forgot.contentTintColor = appearance.secondaryText
            stack.addArrangedSubview(forgot)
        }

        root.addSubview(stack)

        // Preferred position is slightly above centre, but on short displays (13" Airs,
        // scaled resolutions) that put the badge on top of the clock. Keep the stack clear
        // of the clock and inside the screen; the centre offset yields when it must.
        let centerY = stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: compact ? 36 : 60)
        centerY.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            centerY,
            stack.topAnchor.constraint(greaterThanOrEqualTo: clock.stack.bottomAnchor, constant: 20),
            // Keep the centred stack clear of the bottom status pill (it is no longer part of
            // the stack, so nothing else stops them overlapping on short displays).
            stack.bottomAnchor.constraint(lessThanOrEqualTo: status.topAnchor, constant: -12)
        ])

        statusLabel = status

        if FaceUnlockSettings.shared.isReadyForLockScreen {
            // The self-view takes the lock badge's place: same circle, same spot in the stack.
            // It stays hidden until the camera is running, so the padlock shows until then.
            // Transparent hit area over the badge. Added before the self-view so a running scan's
            // preview draws on top of it (the button is disabled then anyway).
            let scanButton = makeFaceScanButton()
            badge.addSubview(scanButton)
            NSLayoutConstraint.activate([
                scanButton.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
                scanButton.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
                scanButton.topAnchor.constraint(equalTo: badge.topAnchor),
                scanButton.bottomAnchor.constraint(equalTo: badge.bottomAnchor)
            ])
            faceScanButton = scanButton
            updateFaceScanButton()

            let selfView = LockFaceSelfView(diameter: badgeDiameter)
            badge.addSubview(selfView)
            NSLayoutConstraint.activate([
                selfView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                selfView.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
            ])
            faceSelfView = selfView
            selfView.setState(faceViewState)
            if let faceSession { selfView.attachPreview(session: faceSession) }
        }
        return root
    }

    private func makeClockBlock(appearance: LockForegroundAppearance, compact: Bool = false) -> (stack: NSStackView, time: NSTextField, date: NSTextField) {
        let time = NSTextField(labelWithString: "")
        // Tabular digits: with proportional figures the clock changes width every second
        // ("1" is narrower than "0"), and since it's centred the whole line jiggles.
        time.font = .monospacedDigitSystemFont(ofSize: compact ? 64 : 88, weight: .semibold)
        time.textColor = appearance.primaryText
        time.alignment = .center
        time.shadow = appearance.textShadow

        let date = NSTextField(labelWithString: "")
        date.font = .systemFont(ofSize: compact ? 16 : 19, weight: .medium)
        date.textColor = appearance.secondaryText
        date.alignment = .center
        date.shadow = appearance.textShadow

        let stack = NSStackView(views: [time, date])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        updateClockLabels(time: time, date: date)
        return (stack, time, date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("j:mm") // respects 12/24h preference
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter
    }()

    private func updateClockLabels(time: NSTextField, date: NSTextField) {
        let now = Date()
        time.stringValue = Self.timeFormatter.string(from: now)
        date.stringValue = Self.dateFormatter.string(from: now)
    }

    private func updateAllClocks() {
        for pair in clockLabels {
            updateClockLabels(time: pair.time, date: pair.date)
        }
    }

    private func startClock() {
        updateAllClocks()
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAllClocks() }
        }
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    /// Builds the lock-screen credential field. Returns the secure field plus the view
    /// to drop into the layout — which, in glass mode, is a translucent container that
    /// gives the field real padding and vertical centering (the bare field had neither).
    private func makeLockInput(
        placeholder: String,
        action: Selector,
        appearance: LockForegroundAppearance,
        glassEnabled: Bool
    ) -> (field: NSSecureTextField, container: NSView) {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 17)
        field.alignment = .center
        field.controlSize = .large
        field.target = self
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false

        guard glassEnabled else {
            field.bezelStyle = .roundedBezel
            field.isBezeled = true
            field.drawsBackground = true
            field.textColor = appearance.fieldText
            field.backgroundColor = appearance.fieldBackground
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return (field, field)
        }

        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = appearance.glassFieldText
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: field.font ?? NSFont.systemFont(ofSize: 17),
                .foregroundColor: appearance.glassFieldPlaceholder
            ]
        )

        let container = LockGlassInputView(appearance: appearance)
        container.addSubview(field)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 320),
            container.heightAnchor.constraint(equalToConstant: 54),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return (field, container)
    }

    private func installLockBackground(in root: NSView) {
        switch settings.backgroundEffectKind {
        case .transparent:
            return
        case .blur:
            installBlurBackground(in: root)
        case .color:
            installColorBackground(in: root)
        case .media:
            installMediaBackground(in: root)
        }
    }

    private func installBlurBackground(in root: NSView) {
        guard settings.blurLevel > 0 else { return }

        let backdrop = NSVisualEffectView()
        backdrop.material = settings.lockMaterial
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.alphaValue = settings.blurEffectOpacity
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(backdrop)
        pinToEdges(backdrop, of: root)

        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(settings.overlayOpacity).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)
        pinToEdges(overlay, of: root)
    }

    private func installColorBackground(in root: NSView) {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = settings.backgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        pinToEdges(view, of: root)
    }

    private func installMediaBackground(in root: NSView) {
        guard let url = settings.backgroundMediaURL, FileManager.default.fileExists(atPath: url.path) else {
            installColorBackground(in: root)
            return
        }

        let view: NSView
        switch settings.backgroundMediaKind {
        case .video:
            view = LockVideoBackgroundView(url: url)
        case .image, .none:
            if let image = NSImage(contentsOf: url) {
                view = LockImageBackgroundView(image: image)
            } else {
                view = NSView()
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.black.cgColor
            }
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        pinToEdges(view, of: root)
    }

    private func sampleScreenBrightness(on screen: NSScreen) -> Double? {
        guard settings.inputAppearanceMode == .auto else {
            return nil
        }

        guard settings.backgroundEffectKind == .transparent || settings.backgroundEffectKind == .blur else {
            return nil
        }

        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID,
              let image = CGDisplayCreateImage(displayID) else {
            return nil
        }

        return Self.averageBrightness(of: image)
    }

    private static func averageBrightness(of image: CGImage) -> Double? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        let step = max(1, min(width, height) / 56)
        var total = 0.0
        var count = 0.0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += color.relativeLuminance
                count += 1
            }
        }

        return count > 0 ? total / count : nil
    }

    private func resetCredentialInput() {
        passwordField?.stringValue = ""
        pinInputView?.reset()
        pinRecoveryField?.stringValue = ""
    }

    private func configureInitialInputState(for trigger: LockTrigger) {
        hotKeyInputGateTimer?.invalidate()
        hotKeyInputGateTimer = nil
        hotKeyInputGatePollTimer?.invalidate()
        hotKeyInputGatePollTimer = nil
        hotKeyInputGate = nil

        switch trigger {
        case .manual:
            setInputEnabled(true)
        case .hotKey(let shortcut):
            hotKeyInputGate = HotKeyInputGate(
                keyCode: shortcut.keyCode,
                requiredFlags: shortcut.cgModifierFlags
            )
            setInputEnabled(false)
            refreshHotKeyInputGateFromCurrentKeyboardState()
            guard hotKeyInputGate != nil else { return }
            hotKeyInputGatePollTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshHotKeyInputGateFromCurrentKeyboardState()
                }
            }
            hotKeyInputGateTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.finishHotKeyInputGate()
                }
            }
        }
    }

    private func observeHotKeyInputGate(type: CGEventType, event: CGEvent) {
        guard var gate = hotKeyInputGate else { return }

        if type == .keyUp {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == gate.keyCode {
                gate.keyReleased = true
            }
        }

        if event.flags.intersection(gate.requiredFlags).isEmpty {
            gate.modifiersReleased = true
        }

        hotKeyInputGate = gate
        refreshHotKeyInputGateFromCurrentKeyboardState()
        if gate.isComplete {
            finishHotKeyInputGate()
        }
    }

    private func refreshHotKeyInputGateFromCurrentKeyboardState() {
        guard var gate = hotKeyInputGate else { return }

        let keyIsStillDown = CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(gate.keyCode)
        )
        if !keyIsStillDown {
            gate.keyReleased = true
        }

        let currentFlags = CGEventSource.flagsState(.combinedSessionState)
        if currentFlags.intersection(gate.requiredFlags).isEmpty {
            gate.modifiersReleased = true
        }

        hotKeyInputGate = gate
        if gate.isComplete {
            finishHotKeyInputGate()
        }
    }

    private func finishHotKeyInputGate() {
        guard hotKeyInputGate != nil else { return }
        hotKeyInputGate = nil
        hotKeyInputGateTimer?.invalidate()
        hotKeyInputGateTimer = nil
        hotKeyInputGatePollTimer?.invalidate()
        hotKeyInputGatePollTimer = nil
        resetCredentialInput()
        setInputEnabled(true)
        activateLock()
    }

    private func installEventTap() {
        let mask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<LockerController>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async {
                    controller.reenableEventTap()
                    controller.maintainLockPresentation(refocusInput: true)
                }
                return Unmanaged.passUnretained(event)
            }

            // Re-grabbing keyboard focus mid-keystroke tears down the secure field's
            // field editor. That drops dead-key/special-character composition (so a
            // password ending in "`" needed two Returns) and wipes the in-progress text
            // the moment a modifier like Shift is pressed (so "@" reset the field).
            // Only steal focus back on pointer events, where the user may actually have
            // clicked away from the input.
            let isKeyboard = type == .keyDown || type == .keyUp || type == .flagsChanged
            DispatchQueue.main.async {
                controller.observeHotKeyInputGate(type: type, event: event)
                controller.maintainLockPresentation(refocusInput: !isKeyboard)
            }

            if LockerController.shouldBlock(event: event, type: type) {
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            if !AXIsProcessTrusted() {
                showStatus("Accessibility access is needed. Remove SoftLock from the list in System Settings and add it again.")
            } else {
                showStatus("Couldn't start input protection — the screen is still locked.")
            }
            AppLog.write("event tap create failed, AX trusted: \(AXIsProcessTrusted())")
            return
        }

        eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), eventSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        AppLog.write("event tap installed")
    }

    private func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        AppLog.write("event tap re-enabled after system disable")
    }

    nonisolated private static func shouldBlock(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .keyDown || type == .flagsChanged else { return false }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let commandHeld = flags.contains(.maskCommand)
        let optionHeld = flags.contains(.maskAlternate)
        let controlHeld = flags.contains(.maskControl)

        if commandHeld && keyCode == 48 { return true }
        if commandHeld && keyCode == 49 { return true }
        if commandHeld && optionHeld && keyCode == 53 { return true }
        if controlHeld && keyCode == 126 { return true }

        return false
    }

    private func activateLock() {
        maintainLockPresentation(refocusInput: true)
    }

    private var lockPresentationOptions: NSApplication.PresentationOptions {
        [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication
        ]
    }

    /// Keep the lock windows frontmost. `refocusInput` should only be true for
    /// pointer events or explicit activation — never per-keystroke, or the secure
    /// field editor gets torn down mid-composition.
    fileprivate func maintainLockPresentation(refocusInput: Bool) {
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            reenableEventTap()
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = lockPresentationOptions
        windows.forEach { $0.orderFrontRegardless() }

        // While the system Touch ID sheet is up, don't steal focus back to the
        // input — that would dismiss the biometric prompt.
        guard refocusInput, !biometricInProgress else { return }
        focusActiveInput()
    }

    private func focusActiveInput() {
        if let pinInputView, !pinInputView.isHidden {
            if pinInputView.window?.firstResponder !== pinInputView {
                pinInputView.window?.makeKeyAndOrderFront(nil)
                pinInputView.window?.makeFirstResponder(pinInputView)
            }
            return
        }

        let field: NSSecureTextField?
        if let pinRecoveryContainer, !pinRecoveryContainer.isHidden {
            field = pinRecoveryField
        } else {
            field = passwordField
        }
        guard let field, !field.isHidden else { return }

        // Don't re-assert focus if the field (or its field editor) already owns it;
        // re-grabbing would needlessly reset the secure text editor.
        let editor = field.window?.fieldEditor(false, for: field)
        let current = field.window?.firstResponder
        if current !== field, current !== editor {
            field.window?.makeKeyAndOrderFront(nil)
            field.becomeFirstResponder()
        }
    }

    private func makeTouchIDButton(appearance: LockForegroundAppearance) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(touchIDTapped))
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        button.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: "Unlock with Touch ID")?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.contentTintColor = appearance.primaryText.withAlphaComponent(0.85)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.toolTip = "Unlock with Touch ID"
        return button
    }

    @objc private func touchIDTapped() {
        attemptBiometricUnlock(automatic: false)
    }

    private static let faceScanHint = "Press Space or tap the camera button to scan your face."

    /// Invisible button laid over the lock badge, whose icon is already the camera glyph.
    private func makeFaceScanButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(faceScanTapped))
        button.isBordered = false
        button.isTransparent = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Scan your face (Space)"
        button.setAccessibilityLabel("Scan your face")
        return button
    }

    /// Off while a scan is running, so a second tap can't stack another scan cycle on it.
    private func updateFaceScanButton() {
        faceScanButton?.isEnabled = !FaceUnlockController.shared.isScanning
    }

    @objc private func faceScanTapped() {
        beginFaceScan()
    }

    /// Space starts a face scan without moving focus off the passcode input. It only fires while
    /// the input is empty, so a space inside a password is still typed as a space.
    private func installFaceScanKeyMonitor() {
        guard faceScanKeyMonitor == nil else { return }
        faceScanKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleFaceScanKey(event) else { return event }
            return nil
        }
    }

    private func removeFaceScanKeyMonitor() {
        if let faceScanKeyMonitor { NSEvent.removeMonitor(faceScanKeyMonitor) }
        faceScanKeyMonitor = nil
    }

    /// True when the event was consumed as the face-scan shortcut.
    private func handleFaceScanKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false } // Space
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        guard !windows.isEmpty, lockoutTimer == nil, !biometricInProgress else { return false }
        guard FaceUnlockSettings.shared.isReadyForLockScreen else { return false }
        guard !FaceUnlockController.shared.isScanning else { return true }
        guard isCredentialInputEmpty else { return false }
        beginFaceScan()
        return true
    }

    /// Nothing typed yet in whichever credential field is on screen.
    private var isCredentialInputEmpty: Bool {
        if let pinRecoveryContainer, !pinRecoveryContainer.isHidden {
            return pinRecoveryField?.stringValue.isEmpty ?? true
        }
        if let pinInputView { return !pinInputView.hasInput }
        return passwordField?.stringValue.isEmpty ?? true
    }

    private func attemptBiometricUnlock(automatic: Bool) {
        // Touch ID has to respect the brute-force lockout too, or the standalone button in
        // password mode offers a way around the backoff the keypad enforces.
        guard lockoutTimer == nil else { return }
        guard settings.useTouchID, BiometricAuth.isAvailable, !biometricInProgress else { return }
        biometricInProgress = true

        BiometricAuth.evaluate(reason: "unlock SoftLock") { [weak self] success in
            guard let self else { return }
            self.biometricInProgress = false

            if success {
                self.unlock(recoveryUsed: false)
            } else {
                // Fall back to the password field; on a manual tap show a hint.
                if !automatic {
                    self.showStatus("Touch ID didn't match. Enter your password.")
                }
                self.activateLock()
            }
        }
    }

    @objc private func submitCredential() {
        guard let credential = passwordField?.stringValue, !credential.isEmpty else { return }
        verifyCredential(credential)
    }

    @objc private func submitRecoveryField() {
        guard let code = pinRecoveryField?.stringValue, !code.isEmpty else { return }
        verifyCredential(code)
    }

    @objc private func toggleRecoveryEntry() {
        guard let recoveryField = pinRecoveryField,
              let recoveryContainer = pinRecoveryContainer,
              let pinView = pinInputView else { return }
        let showRecovery = recoveryContainer.isHidden
        recoveryContainer.isHidden = !showRecovery
        pinView.isHidden = showRecovery
        showStatus(showRecovery ? "Enter your recovery code." : "", tone: .info)
        if showRecovery {
            recoveryField.stringValue = ""
            recoveryField.window?.makeFirstResponder(recoveryField)
        } else {
            // The keypad was hidden (and so lost first responder) while recovery was open.
            pinView.window?.makeFirstResponder(pinView)
        }
    }

    private func verifyCredential(_ credential: String) {
        guard !credential.isEmpty else { return }

        switch store.verify(credential: credential) {
        case .password:
            unlock(recoveryUsed: false)
        case .recovery:
            unlock(recoveryUsed: true)
        case .invalid:
            failedAttempts += 1
            passwordField?.stringValue = ""
            pinRecoveryField?.stringValue = ""
            pinInputView?.reset()
            captureFailedAttemptIfNeeded()
            applyThrottleOrShowError()
        }
    }

    /// After repeated wrong entries, lock input for a growing delay. This matters most for
    /// short PINs, where the keyspace is small enough to brute-force without a backoff.
    private func applyThrottleOrShowError() {
        let delay = Self.throttleDelay(for: failedAttempts)
        guard delay > 0 else {
            showStatus(credentialErrorText)
            return
        }
        beginLockout(seconds: delay)
    }

    private static func throttleDelay(for attempts: Int) -> Int {
        guard attempts >= 3 else { return 0 }
        let step = attempts - 2                 // 1, 2, 3, ...
        return min(60, 5 * (1 << min(step - 1, 4)))   // 5, 10, 20, 40, 60s
    }

    private func beginLockout(seconds: Int) {
        lockoutRemaining = seconds
        setInputEnabled(false)
        showStatus("Too many attempts. Try again in \(lockoutRemaining)s.")

        lockoutTimer?.invalidate()
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLockout() }
        }
    }

    private func tickLockout() {
        lockoutRemaining -= 1
        if lockoutRemaining <= 0 {
            lockoutTimer?.invalidate()
            lockoutTimer = nil
            setInputEnabled(true)
            showStatus("")
        } else {
            showStatus("Too many attempts. Try again in \(lockoutRemaining)s.")
        }
    }

    private func setInputEnabled(_ enabled: Bool) {
        passwordField?.isEnabled = enabled
        pinInputView?.isEnabled = enabled
        pinRecoveryField?.isEnabled = enabled
        if enabled, settings.unlockStyle == .password {
            passwordField?.becomeFirstResponder()
        }
    }

    private func showStatus(_ text: String, tone: FaceUnlockStatusKind = .error) {
        statusLabel?.show(text, tone: tone)
    }

    private func captureFailedAttemptIfNeeded() {
        guard settings.capturePhotoOnFailure else { return }

        FailedAttemptCamera.shared.capture(maxPhotos: settings.maxFailedAttemptPhotos) { result in
            switch result {
            case .success(let url):
                AppLog.write("failed attempt photo saved: \(url.path)")
            case .failure(let error):
                AppLog.write("failed attempt photo failed: \(error.localizedDescription)")
            }
        }
    }

    /// Dismiss the lock screen *without* a passcode because the user already proved
    /// ownership by unlocking the real macOS login screen. This avoids a second password
    /// prompt and is the forgot-PIN escape hatch: log into macOS and SoftLock releases,
    /// so the machine is never stranded behind a passcode the user no longer remembers.
    func standDown() {
        guard !windows.isEmpty else { return }
        AppLog.write("standDown: releasing after trusted macOS unlock")
        unlock(recoveryUsed: false)
    }

    private func unlock(recoveryUsed: Bool) {
        AppLog.write("unlock begin recoveryUsed=\(recoveryUsed)")
        FaceUnlockController.shared.stop()
        FaceUnlockController.shared.noteUnlockedByOtherMeans()
        removeFaceScanKeyMonitor()
        faceSession = nil
        faceViewState = .scanning
        faceSelfView?.detach()
        stopObservingDisplayChanges()
        lockoutTimer?.invalidate()
        lockoutTimer = nil
        hotKeyInputGateTimer?.invalidate()
        hotKeyInputGateTimer = nil
        hotKeyInputGatePollTimer?.invalidate()
        hotKeyInputGatePollTimer = nil
        hotKeyInputGate = nil
        stopClock()
        uninstallEventTap()

        windows.forEach { $0.orderOut(nil) }
        NSApp.presentationOptions = []
        onUnlock(recoveryUsed)
        AppLog.write("unlock end")
    }

    private func uninstallEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        if let eventSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventSource, .commonModes)
        }

        eventTap = nil
        eventSource = nil
        AppLog.write("event tap uninstalled")
    }
}

/// Top-left origin so it works as a scroll view's document view without the content
/// drifting to the bottom of the clip view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class LockWindow: NSWindow {
    let displayID: UInt32?
    /// Whether the content was laid out for a short display; see `LockerController.isCompact`.
    var builtCompact = false

    init(screen: NSScreen) {
        displayID = screen.directDisplayID
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        setFrame(screen.frame, display: true)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        // We keep these windows in a Swift array; without this, close() releases the
        // window while ARC still holds it → intermittent double-free crash.
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        canHide = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Never let AppKit nudge the window out of the exact display frame (it otherwise
    /// shrinks/moves windows to clear the menu bar or a notch, leaving the lock overlay
    /// offset with a strip of desktop showing).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private extension NSScreen {
    var directDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private extension NSWindow {
    /// Center on the screen the user is currently on (the one under the pointer, which is
    /// also the screen whose menu bar they just clicked), not always the primary display.
    func centerOnActiveScreen() {
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private extension NSScreen {
    static var screenUnderMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

@MainActor
private func pinToEdges(_ child: NSView, of parent: NSView) {
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        child.topAnchor.constraint(equalTo: parent.topAnchor),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
    ])
}

private final class LockImageBackgroundView: NSView {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The aspect-fill rect depends on bounds; redraw whenever the display is resized so a
    // resolution/scale change doesn't leave the picture at the old size and offset.
    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }

        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

private final class LockVideoBackgroundView: NSView {
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private var observer: NSObjectProtocol?

    init(url: URL) {
        self.player = AVPlayer(url: url)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? player.pause() : player.play()
    }
}

private enum LockForegroundAppearance {
    case light
    case dark

    var usesLightContent: Bool { self == .light }

    var primaryText: NSColor {
        switch self {
        case .light: return .white
        case .dark: return NSColor.black.withAlphaComponent(0.88)
        }
    }

    var secondaryText: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.70)
        case .dark: return NSColor.black.withAlphaComponent(0.62)
        }
    }

    var tertiaryText: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.38)
        case .dark: return NSColor.black.withAlphaComponent(0.34)
        }
    }

    var statusText: NSColor {
        switch self {
        case .light: return NSColor.systemRed.blended(withFraction: 0.28, of: .white) ?? .systemRed
        case .dark: return NSColor.systemRed.blended(withFraction: 0.12, of: .black) ?? .systemRed
        }
    }

    var badgeBackground: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.14)
        case .dark: return NSColor.black.withAlphaComponent(0.10)
        }
    }

    var badgeBorder: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.22)
        case .dark: return NSColor.black.withAlphaComponent(0.18)
        }
    }

    var fieldText: NSColor {
        switch self {
        case .light: return .labelColor
        case .dark: return .labelColor
        }
    }

    var fieldBackground: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.92)
        case .dark: return NSColor.white.withAlphaComponent(0.78)
        }
    }

    var glassFieldText: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.96)
        case .dark: return NSColor.black.withAlphaComponent(0.86)
        }
    }

    var glassFieldPlaceholder: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.58)
        case .dark: return NSColor.black.withAlphaComponent(0.46)
        }
    }

    /// Frosted material behind the glass input. A dark HUD material reads as glass over
    /// bright/photographic backgrounds; a light popover material suits dark text on a
    /// bright background.
    var glassInputMaterial: NSVisualEffectView.Material {
        switch self {
        case .light: return .hudWindow
        case .dark: return .popover
        }
    }

    /// Subtle tint laid over the frosted material so the field keeps a hint of color
    /// without washing out the blur underneath.
    var glassInputTint: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.10)
        case .dark: return NSColor.white.withAlphaComponent(0.22)
        }
    }

    /// Thin top highlight that sells the "liquid glass" edge.
    var glassInputHighlight: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.55)
        case .dark: return NSColor.white.withAlphaComponent(0.70)
        }
    }

    var glassInputBackground: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.13)
        case .dark: return NSColor.white.withAlphaComponent(0.44)
        }
    }

    var glassInputBorder: NSColor {
        switch self {
        case .light: return NSColor.white.withAlphaComponent(0.34)
        case .dark: return NSColor.white.withAlphaComponent(0.62)
        }
    }

    var glassInputShadow: NSColor {
        switch self {
        case .light: return NSColor.black.withAlphaComponent(0.34)
        case .dark: return NSColor.black.withAlphaComponent(0.18)
        }
    }

    var textShadow: NSShadow {
        let shadow = NSShadow()
        switch self {
        case .light:
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 9
            shadow.shadowOffset = CGSize(width: 0, height: -1)
        case .dark:
            shadow.shadowColor = NSColor.white.withAlphaComponent(0.58)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = CGSize(width: 0, height: -1)
        }
        return shadow
    }
}

@MainActor
private func makeWindowBackgroundView() -> NSView {
    let background = NSVisualEffectView()
    background.material = .windowBackground
    background.blendingMode = .behindWindow
    background.state = .active
    return background
}

@MainActor
private func makeGlassPanel() -> NSView {
    let panel = NSVisualEffectView()
    panel.material = .contentBackground
    panel.blendingMode = .withinWindow
    panel.state = .active
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.wantsLayer = true
    panel.layer?.cornerRadius = 16
    panel.layer?.cornerCurve = .continuous
    panel.layer?.masksToBounds = true
    panel.layer?.borderWidth = 0.5
    panel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    return panel
}

@MainActor
private func makeLockBadge(
    appearance: LockForegroundAppearance,
    diameter: CGFloat = 76,
    symbolName: String = "lock.fill",
    symbolDescription: String = "Locked"
) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.cornerRadius = diameter / 2
    container.layer?.cornerCurve = .continuous
    container.layer?.backgroundColor = appearance.badgeBackground.cgColor
    container.layer?.borderWidth = 1
    container.layer?.borderColor = appearance.badgeBorder.cgColor
    container.translatesAutoresizingMaskIntoConstraints = false

    let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolDescription)?
        .withSymbolConfiguration(config)
    let imageView = NSImageView(image: symbol ?? NSImage())
    imageView.contentTintColor = appearance.primaryText
    imageView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(imageView)

    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: diameter),
        container.heightAnchor.constraint(equalToConstant: diameter),
        imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor)
    ])
    return container
}

/// Translucent, frosted container for the lock-screen credential field. Uses a real
/// `NSVisualEffectView` so the background blurs whatever is behind it, with a tint, a
/// hairline border and a top highlight to give the genuine "liquid glass" look — the
/// previous flat semi-transparent layer never quite read as glass.
@MainActor
private final class LockGlassInputView: NSView {
    private let highlight = CALayer()

    init(appearance: LockForegroundAppearance) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let radius: CGFloat = 16
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = appearance.glassInputBorder.cgColor
        layer?.shadowColor = appearance.glassInputShadow.cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -12)

        let blur = NSVisualEffectView()
        blur.material = appearance.glassInputMaterial
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = appearance.glassInputTint.cgColor
        tint.layer?.cornerRadius = radius
        tint.layer?.cornerCurve = .continuous
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        highlight.backgroundColor = appearance.glassInputHighlight.cgColor
        highlight.cornerRadius = 1
        layer?.addSublayer(highlight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // A thin highlight strip just inside the top edge. Implicit animation is off so the
        // strip doesn't visibly slide in from a zero frame on first layout / on resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let inset: CGFloat = 14
        highlight.frame = CGRect(x: inset, y: bounds.maxY - 2, width: max(0, bounds.width - inset * 2), height: 1.5)
    }
}

private enum BackgroundEffectKind: String, CaseIterable {
    case transparent
    case blur
    case color
    case media

    var title: String {
        switch self {
        case .transparent: return "Transparent"
        case .blur: return "Blur"
        case .color: return "Color"
        case .media: return "Image / Video"
        }
    }
}

private enum BackgroundMediaKind: String {
    case image
    case video

    var defaultPathExtension: String {
        switch self {
        case .image: return "png"
        case .video: return "mov"
        }
    }
}

private enum BackgroundMediaError: LocalizedError {
    case unsupportedMadeDesktop

    var errorDescription: String? {
        switch self {
        case .unsupportedMadeDesktop:
            return "The .madesktop file does not point to a readable wallpaper thumbnail."
        }
    }
}

private enum InputAppearanceMode: String, CaseIterable {
    case auto
    case light
    case dark

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

private struct SystemWallpaperAsset {
    let title: String
    let sourceURL: URL
    let thumbnailURL: URL?
    let isVideo: Bool

    var previewImage: NSImage? {
        if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
            return image
        }

        if !isVideo, let image = NSImage(contentsOf: sourceURL) {
            return image
        }

        return Self.videoFrame(for: sourceURL)
    }

    private static func videoFrame(for url: URL) -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 420, height: 260)
        guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

private enum SystemWallpaperLibrary {
    private static let desktopPicturesURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
    private static let wallpaperVideosURL = desktopPicturesURL.appendingPathComponent(".wallpapers", isDirectory: true)
    private static let userAerialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)

    static func assets() -> [SystemWallpaperAsset] {
        var assets: [SystemWallpaperAsset] = []
        var seen = Set<String>()
        let userAerialNames = userAerialTitleMap()

        for url in files(in: desktopPicturesURL, recursive: false) {
            let ext = url.pathExtension.lowercased()
            if ext == "madesktop", let asset = madeDesktopAsset(from: url), seen.insert(asset.title).inserted {
                assets.append(asset)
            } else if isSupportedMediaExtension(ext), !isThumbnail(url), seen.insert(url.path).inserted {
                assets.append(mediaAsset(from: url))
            }
        }

        for url in files(in: wallpaperVideosURL, recursive: true) where isSupportedMediaExtension(url.pathExtension.lowercased()) {
            guard !isThumbnail(url), seen.insert(url.path).inserted else { continue }
            assets.append(mediaAsset(from: url, thumbnailURL: siblingThumbnail(for: url)))
        }

        let userVideosURL = userAerialsURL.appendingPathComponent("videos", isDirectory: true)
        let userThumbnailsURL = userAerialsURL.appendingPathComponent("thumbnails", isDirectory: true)
        for url in files(in: userVideosURL, recursive: false) where isSupportedMediaExtension(url.pathExtension.lowercased()) {
            guard seen.insert(url.path).inserted else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let thumbnailURL = userThumbnailsURL.appendingPathComponent("\(id).png")
            assets.append(SystemWallpaperAsset(
                title: userAerialNames[id] ?? "Aerial \(id.prefix(8))",
                sourceURL: url,
                thumbnailURL: FileManager.default.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil,
                isVideo: true
            ))
        }

        return assets.sorted { left, right in
            if left.isVideo != right.isVideo {
                return left.isVideo && !right.isVideo
            }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private static func files(in directory: URL, recursive: Bool) -> [URL] {
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { item in
                guard let url = item as? URL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return nil
                }
                return url
            }
        }

        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        } ?? []
    }

    private static func madeDesktopAsset(from url: URL) -> SystemWallpaperAsset? {
        guard let thumbnailURL = madeDesktopThumbnailURL(from: url) else { return nil }
        return SystemWallpaperAsset(
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            thumbnailURL: thumbnailURL,
            isVideo: false
        )
    }

    private static func mediaAsset(from url: URL, thumbnailURL: URL? = nil) -> SystemWallpaperAsset {
        SystemWallpaperAsset(
            title: cleanTitle(from: url),
            sourceURL: url,
            thumbnailURL: thumbnailURL,
            isVideo: url.conformsToMovie
        )
    }

    private static func siblingThumbnail(for url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return urls.first { candidate in
            let name = candidate.lastPathComponent.lowercased()
            return name.contains("thumbnail") && ["png", "jpg", "jpeg", "heic"].contains(candidate.pathExtension.lowercased())
        }
    }

    private static func cleanTitle(from url: URL) -> String {
        var title = url.deletingPathExtension().lastPathComponent
        for suffix in [" Landscape", " Portrait", " Light", " Dark"] {
            if title.hasSuffix(suffix) {
                title.removeLast(suffix.count)
            }
        }
        return title
    }

    private static func isSupportedMediaExtension(_ ext: String) -> Bool {
        ["heic", "jpg", "jpeg", "png", "mov", "mp4", "m4v"].contains(ext)
    }

    private static func isThumbnail(_ url: URL) -> Bool {
        url.lastPathComponent.localizedCaseInsensitiveContains("Thumbnail")
    }

    private static func userAerialTitleMap() -> [String: String] {
        let entriesURL = userAerialsURL
            .appendingPathComponent("manifest", isDirectory: true)
            .appendingPathComponent("entries.json")
        guard let data = try? Data(contentsOf: entriesURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["assets"] as? [[String: Any]] else {
            return [:]
        }

        var result: [String: String] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            if let label = entry["accessibilityLabel"] as? String, !label.isEmpty {
                result[id] = label
            }
        }
        return result
    }
}

@MainActor
private final class WallpaperPickerWindowController: NSObject {
    let window: NSWindow
    private let assets: [SystemWallpaperAsset]
    private let onSelect: (SystemWallpaperAsset) -> Void
    private let segmented = NSSegmentedControl(labels: ["Photos", "Videos"], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = NSScrollView()

    init(assets: [SystemWallpaperAsset], onSelect: @escaping (SystemWallpaperAsset) -> Void) {
        self.assets = assets
        self.onSelect = onSelect
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    private func build() {
        window.title = "Apple Wallpapers"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false

        let root = makeWindowBackgroundView()
        let title = NSTextField(labelWithString: "Apple Wallpapers")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let closeButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        closeButton.bezelStyle = .rounded
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeButton)

        segmented.selectedSegment = 0
        segmented.segmentStyle = .rounded
        segmented.target = self
        segmented.action = #selector(tabChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(segmented)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        installGrid(makeGrid(for: filteredAssets))
        root.addSubview(scrollView)
        window.contentView = root

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            segmented.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            segmented.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
    }

    /// Hosts the grid in a flipped document view pinned to the clip view's top-left. A plain
    /// (non-flipped) document sits at the *bottom* of the scroll view whenever the content
    /// is shorter than the viewport — e.g. the Videos tab with a few items or the empty
    /// state — and starts scrolled to the wrong end.
    private func installGrid(_ grid: NSStackView) {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
        // A new tab always starts at the top rather than inheriting the previous tab's offset.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var filteredAssets: [SystemWallpaperAsset] {
        let wantsVideo = segmented.selectedSegment == 1
        return assets.filter { $0.isVideo == wantsVideo }
    }

    @objc private func tabChanged() {
        installGrid(makeGrid(for: filteredAssets))
    }

    private func makeGrid(for assets: [SystemWallpaperAsset]) -> NSStackView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 14
        outer.translatesAutoresizingMaskIntoConstraints = false

        let columns = 4
        guard !assets.isEmpty else {
            let empty = NSTextField(labelWithString: "No wallpapers found in this tab.")
            empty.font = .systemFont(ofSize: 13, weight: .medium)
            empty.textColor = .secondaryLabelColor
            outer.addArrangedSubview(empty)
            return outer
        }

        for chunkStart in stride(from: 0, to: assets.count, by: columns) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            // 4 x 164 + 3 x 12 = 692pt: fits the 712pt viewport even when a legacy (always
            // visible) scroller takes 15pt, where the old 14pt gaps (698pt) clipped column 4.
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false

            for asset in assets[chunkStart..<min(chunkStart + columns, assets.count)] {
                let tile = WallpaperTileView(asset: asset) { [weak self] selected in
                    self?.select(selected)
                }
                row.addArrangedSubview(tile)
            }

            outer.addArrangedSubview(row)
        }

        return outer
    }

    private func select(_ asset: SystemWallpaperAsset) {
        onSelect(asset)
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
    }

    @objc private func cancel() {
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
    }
}

@MainActor
private final class WallpaperTileView: NSControl {
    private let asset: SystemWallpaperAsset
    private let onSelect: (SystemWallpaperAsset) -> Void

    init(asset: SystemWallpaperAsset, onSelect: @escaping (SystemWallpaperAsset) -> Void) {
        self.asset = asset
        self.onSelect = onSelect
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.68).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.42).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        // Aspect-fill thumbnail. `.scaleAxesIndependently` stretched every wallpaper to the
        // fixed 148x88 slot, distorting anything that isn't exactly that ratio.
        let imageView = NSView()
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 7
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.contentsGravity = .resizeAspectFill
        imageView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        imageView.layer?.contents = asset.previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        let label = NSTextField(labelWithString: asset.title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let badge = NSTextField(labelWithString: asset.isVideo ? "Video" : "Image")
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.cornerCurve = .continuous
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(asset.isVideo ? 0.52 : 0.34).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 164),
            heightAnchor.constraint(equalToConstant: 132),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.heightAnchor.constraint(equalToConstant: 88),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
            badge.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -6),
            badge.widthAnchor.constraint(equalToConstant: asset.isVideo ? 42 : 40),
            badge.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    override func mouseDown(with event: NSEvent) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        onSelect(asset)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.68).cgColor
    }
}

private struct LockBackgroundSwatch {
    let id: String
    let title: String
    let color: NSColor

    static let defaultID = "black"

    static let all: [LockBackgroundSwatch] = [
        LockBackgroundSwatch(id: "black", title: "Black", color: NSColor(calibratedWhite: 0.02, alpha: 1)),
        LockBackgroundSwatch(id: "graphite", title: "Graphite", color: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)),
        LockBackgroundSwatch(id: "navy", title: "Navy", color: NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.18, alpha: 1)),
        LockBackgroundSwatch(id: "forest", title: "Forest", color: NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.12, alpha: 1)),
        LockBackgroundSwatch(id: "burgundy", title: "Burgundy", color: NSColor(calibratedRed: 0.22, green: 0.04, blue: 0.08, alpha: 1)),
        LockBackgroundSwatch(id: "slate", title: "Slate", color: NSColor(calibratedRed: 0.42, green: 0.46, blue: 0.50, alpha: 1)),
        LockBackgroundSwatch(id: "fog", title: "Fog", color: NSColor(calibratedWhite: 0.86, alpha: 1)),
        LockBackgroundSwatch(id: "white", title: "White", color: NSColor(calibratedWhite: 0.96, alpha: 1))
    ]

    static func swatch(for id: String) -> LockBackgroundSwatch {
        all.first { $0.id == id } ?? all[0]
    }
}

private extension NSColor {
    var relativeLuminance: Double {
        guard let color = usingColorSpace(.deviceRGB) else { return 0 }
        func convert(_ value: CGFloat) -> Double {
            let channel = Double(value)
            if channel <= 0.03928 {
                return channel / 12.92
            }
            return pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * convert(color.redComponent) +
            0.7152 * convert(color.greenComponent) +
            0.0722 * convert(color.blueComponent)
    }
}

private extension URL {
    var conformsToMovie: Bool {
        if let values = try? resourceValues(forKeys: [.contentTypeKey]),
           values.contentType?.conforms(to: .movie) == true {
            return true
        }
        return ["mov", "mp4", "m4v"].contains(pathExtension.lowercased())
    }
}

private extension AVAuthorizationStatus {
    var permissionDetail: String {
        switch self {
        case .authorized:
            return "ready"
        case .notDetermined:
            return "not requested yet"
        case .denied:
            return "denied in System Settings"
        case .restricted:
            return "restricted by system policy"
        @unknown default:
            return "unknown status"
        }
    }
}

private func madeDesktopThumbnailURL(from url: URL) -> URL? {
    guard url.pathExtension.lowercased() == "madesktop",
          let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dictionary = plist as? [String: Any],
          let thumbnailPath = dictionary["thumbnailPath"] as? String,
          !thumbnailPath.isEmpty else {
        return nil
    }

    let thumbnailURL = URL(fileURLWithPath: thumbnailPath)
    return FileManager.default.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil
}

@MainActor
private final class AppSettings {
    static let shared = AppSettings()
    static let defaultLockTitle = "SoftLock"
    static let defaultBlurLevel = 0.56
    static let defaultMaxFailedAttemptPhotos = 20

    private let defaults = UserDefaults.standard
    private let titleKey = "lockTitle"
    private let backgroundEffectKey = "backgroundEffectKind"
    private let blurKey = "blurLevel"
    private let backgroundColorKey = "backgroundColorID"
    private let backgroundMediaPathKey = "backgroundMediaPath"
    private let backgroundMediaKindKey = "backgroundMediaKind"
    private let backgroundMediaDisplayNameKey = "backgroundMediaDisplayName"
    private let backgroundMediaBrightnessKey = "backgroundMediaBrightness"
    private let inputAppearanceKey = "inputAppearanceMode"
    private let liquidGlassInputsKey = "liquidGlassInputsEnabled"
    private let captureKey = "capturePhotoOnFailure"
    private let maxPhotosKey = "maxFailedAttemptPhotos"
    private let touchIDKey = "useTouchID"
    private let unlockStyleKey = "unlockStyle"
    private let pinLengthKey = "pinLength"
    private let shortcutKeyCodeKey = "lockShortcutKeyCode"
    private let shortcutModifiersKey = "lockShortcutModifiers"
    private let shortcutLabelKey = "lockShortcutLabel"
    private let shortcutsKey = "lockShortcuts"

    static let shortcutChangedNotification = Notification.Name("softlock.shortcutChanged")

    // Default: ⌃⌥⌘L  (keyCode 37 == "L")
    static let defaultShortcutKeyCode = 37
    static let defaultShortcutModifiers = Int(
        NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )
    static let defaultShortcut = LockShortcut(
        keyCode: defaultShortcutKeyCode,
        modifiers: defaultShortcutModifiers,
        label: "L"
    )

    /// All shortcuts that trigger the lock. More than one combo is allowed so each
    /// physical keyboard (built-in vs an external one with a different layout) can
    /// have its own. Never empty; duplicates of the same combo are dropped.
    var lockShortcuts: [LockShortcut] {
        get {
            if let data = defaults.data(forKey: shortcutsKey),
               let stored = try? JSONDecoder().decode([LockShortcut].self, from: data),
               !stored.isEmpty {
                return stored
            }
            // Migrate the pre-0.4 single-shortcut keys.
            if defaults.object(forKey: shortcutKeyCodeKey) != nil {
                return [LockShortcut(
                    keyCode: defaults.integer(forKey: shortcutKeyCodeKey),
                    modifiers: defaults.integer(forKey: shortcutModifiersKey),
                    label: defaults.string(forKey: shortcutLabelKey) ?? ""
                )]
            }
            return [Self.defaultShortcut]
        }
        set {
            var deduped: [LockShortcut] = []
            for shortcut in newValue where !deduped.contains(where: { $0.sameKey(as: shortcut) }) {
                deduped.append(shortcut)
            }
            if deduped.isEmpty { deduped = [Self.defaultShortcut] }
            if let data = try? JSONEncoder().encode(deduped) {
                defaults.set(data, forKey: shortcutsKey)
            }
            NotificationCenter.default.post(name: Self.shortcutChangedNotification, object: nil)
        }
    }

    /// How the credential is entered. `.pin` shows the iPhone-style keypad.
    var unlockStyle: UnlockStyle {
        get { UnlockStyle(rawValue: defaults.string(forKey: unlockStyleKey) ?? "") ?? .password }
        set { defaults.set(newValue.rawValue, forKey: unlockStyleKey) }
    }

    /// Number of PIN digits (4 or 6). Only meaningful when `unlockStyle == .pin`.
    var pinLength: Int {
        get {
            let value = defaults.integer(forKey: pinLengthKey)
            return value == 6 ? 6 : 4
        }
        set { defaults.set(newValue == 6 ? 6 : 4, forKey: pinLengthKey) }
    }

    var useTouchID: Bool {
        get {
            // Default on when the Mac actually supports biometrics.
            if defaults.object(forKey: touchIDKey) == nil {
                return BiometricAuth.isAvailable
            }
            return defaults.bool(forKey: touchIDKey)
        }
        set {
            defaults.set(newValue, forKey: touchIDKey)
        }
    }

    var lockTitle: String {
        get {
            defaults.string(forKey: titleKey) ?? Self.defaultLockTitle
        }
        set {
            let value = newValue.isEmpty ? Self.defaultLockTitle : newValue
            defaults.set(value, forKey: titleKey)
        }
    }

    var displayTitle: String {
        let trimmed = lockTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultLockTitle : trimmed
    }

    var backgroundEffectKind: BackgroundEffectKind {
        get {
            if defaults.object(forKey: backgroundEffectKey) == nil {
                return .blur
            }
            return BackgroundEffectKind(rawValue: defaults.string(forKey: backgroundEffectKey) ?? "") ?? .blur
        }
        set {
            defaults.set(newValue.rawValue, forKey: backgroundEffectKey)
        }
    }

    var blurLevel: Double {
        get {
            if defaults.object(forKey: blurKey) == nil {
                return Self.defaultBlurLevel
            }

            return min(max(defaults.double(forKey: blurKey), 0.0), 1.0)
        }
        set {
            defaults.set(min(max(newValue, 0.0), 1.0), forKey: blurKey)
        }
    }

    /// Opacity for the system blur layer. 0% is clear; 100% reaches full system blur.
    var blurEffectOpacity: CGFloat {
        CGFloat(pow(blurLevel, 0.85))
    }

    var backgroundColorID: String {
        get {
            defaults.string(forKey: backgroundColorKey) ?? LockBackgroundSwatch.defaultID
        }
        set {
            defaults.set(newValue, forKey: backgroundColorKey)
        }
    }

    var backgroundColor: NSColor {
        LockBackgroundSwatch.swatch(for: backgroundColorID).color
    }

    var inputAppearanceMode: InputAppearanceMode {
        get {
            InputAppearanceMode(rawValue: defaults.string(forKey: inputAppearanceKey) ?? "") ?? .auto
        }
        set {
            defaults.set(newValue.rawValue, forKey: inputAppearanceKey)
        }
    }

    var liquidGlassInputsEnabled: Bool {
        get {
            defaults.bool(forKey: liquidGlassInputsKey)
        }
        set {
            defaults.set(newValue, forKey: liquidGlassInputsKey)
        }
    }

    var backgroundMediaURL: URL? {
        guard let path = defaults.string(forKey: backgroundMediaPathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    var backgroundMediaKind: BackgroundMediaKind? {
        BackgroundMediaKind(rawValue: defaults.string(forKey: backgroundMediaKindKey) ?? "")
    }

    var backgroundMediaDisplayName: String {
        defaults.string(forKey: backgroundMediaDisplayNameKey) ?? backgroundMediaURL?.lastPathComponent ?? "No file"
    }

    func resolvedInputAppearance(screenBrightness: Double? = nil) -> LockForegroundAppearance {
        switch inputAppearanceMode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .auto:
            return autoInputAppearance(screenBrightness: screenBrightness)
        }
    }

    private func autoInputAppearance(screenBrightness: Double?) -> LockForegroundAppearance {
        switch backgroundEffectKind {
        case .color:
            return backgroundColor.relativeLuminance > 0.58 ? .dark : .light
        case .media:
            let brightness = defaults.double(forKey: backgroundMediaBrightnessKey)
            if brightness > 0 {
                return brightness > 0.58 ? .dark : .light
            }
            return .light
        case .transparent, .blur:
            if let screenBrightness {
                return screenBrightness > 0.58 ? .dark : .light
            }
            return .light
        }
    }

    /// Dark overlay on top of the frosted blur. Starts at 0 so 0% means no blur/no dim.
    var overlayOpacity: CGFloat {
        CGFloat(pow(blurLevel, 1.35) * 0.78)
    }

    /// Frost intensity for the lock background. Heavier materials at higher slider values
    /// obscure more of the desktop behind.
    var lockMaterial: NSVisualEffectView.Material {
        if blurLevel < 0.25 {
            return .underWindowBackground
        }
        if blurLevel < 0.55 {
            return .hudWindow
        }
        return .fullScreenUI
    }

    func storeBackgroundMedia(from sourceURL: URL) throws {
        let importURL = try Self.resolvedMediaURL(for: sourceURL)
        let mediaKind = try Self.mediaKind(for: importURL)
        let directory = try Self.backgroundMediaDirectory()
        let destination = directory.appendingPathComponent("LockBackground.\(importURL.pathExtension.isEmpty ? mediaKind.defaultPathExtension : importURL.pathExtension)")

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: importURL, to: destination)

        defaults.set(destination.path, forKey: backgroundMediaPathKey)
        defaults.set(mediaKind.rawValue, forKey: backgroundMediaKindKey)
        defaults.set(Self.displayName(for: sourceURL, resolvedURL: importURL), forKey: backgroundMediaDisplayNameKey)
        if mediaKind == .image, let brightness = Self.averageBrightness(of: destination) {
            defaults.set(brightness, forKey: backgroundMediaBrightnessKey)
        } else {
            defaults.set(-1.0, forKey: backgroundMediaBrightnessKey)
        }
    }

    func clearBackgroundMedia() {
        if let backgroundMediaURL, FileManager.default.fileExists(atPath: backgroundMediaURL.path) {
            try? FileManager.default.removeItem(at: backgroundMediaURL)
        }
        defaults.removeObject(forKey: backgroundMediaPathKey)
        defaults.removeObject(forKey: backgroundMediaKindKey)
        defaults.removeObject(forKey: backgroundMediaDisplayNameKey)
        defaults.removeObject(forKey: backgroundMediaBrightnessKey)
    }

    /// Wipe every stored preference (used by Delete SoftLock).
    func eraseForUninstall() {
        clearBackgroundMedia()
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.removePersistentDomain(forName: appIdentifier)
        defaults.synchronize()
    }

    private static func backgroundMediaDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("SoftLock", isDirectory: true)
        .appendingPathComponent("Backgrounds", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func mediaKind(for url: URL) throws -> BackgroundMediaKind {
        if url.conformsToMovie {
            return .video
        }

        let values = try url.resourceValues(forKeys: [.contentTypeKey])
        if values.contentType?.conforms(to: .movie) == true {
            return .video
        }
        return .image
    }

    private static func resolvedMediaURL(for url: URL) throws -> URL {
        guard url.pathExtension.lowercased() == "madesktop" else {
            return url
        }

        guard let thumbnailURL = madeDesktopThumbnailURL(from: url) else {
            throw BackgroundMediaError.unsupportedMadeDesktop
        }
        return thumbnailURL
    }

    private static func displayName(for sourceURL: URL, resolvedURL: URL) -> String {
        if sourceURL.pathExtension.lowercased() == "madesktop" {
            return sourceURL.deletingPathExtension().lastPathComponent
        }
        return sourceURL.lastPathComponent.isEmpty ? resolvedURL.lastPathComponent : sourceURL.lastPathComponent
    }

    private static func averageBrightness(of url: URL) -> Double? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return nil }

        let step = max(1, min(width, height) / 48)
        var total = 0.0
        var count = 0.0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += color.relativeLuminance
                count += 1
            }
        }

        return count > 0 ? total / count : nil
    }

    var capturePhotoOnFailure: Bool {
        get {
            defaults.bool(forKey: captureKey)
        }
        set {
            defaults.set(newValue, forKey: captureKey)
        }
    }

    var maxFailedAttemptPhotos: Int {
        get {
            if defaults.object(forKey: maxPhotosKey) == nil {
                return Self.defaultMaxFailedAttemptPhotos
            }

            return min(max(defaults.integer(forKey: maxPhotosKey), 1), 100)
        }
        set {
            defaults.set(min(max(newValue, 1), 100), forKey: maxPhotosKey)
        }
    }

    var launchAtLoginStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    var launchAtLoginUnavailableReason: String {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path

        guard bundleURL.pathExtension == "app" else {
            return "Run app bundle"
        }

        if path.hasPrefix("/Volumes/") {
            return "Move to Applications"
        }

        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .path
        if !path.hasPrefix("/Applications/") && !path.hasPrefix(userApplications + "/") {
            return "Install app first"
        }

        return "Unavailable"
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled, service.status != .requiresApproval else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}

private enum CredentialResult {
    case password
    case recovery
    case invalid
}

enum UnlockStyle: String {
    case password
    case pin
}

@MainActor
private final class FailedAttemptCamera: NSObject, AVCapturePhotoCaptureDelegate {
    static let shared = FailedAttemptCamera()

    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var maxPhotos = 20
    private var isCapturing = false
    /// `startRunning()`/`stopRunning()` block their caller. Running them on the main thread
    /// froze the lock screen for up to a second after every wrong passcode.
    private let sessionQueue = DispatchQueue(label: "\(appIdentifier).camera")

    func capture(maxPhotos: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        // Wrong passcodes can arrive faster than a capture completes. Without this guard the
        // in-flight completion is dropped, a second AVCaptureSession is configured on top of
        // the first, and the camera is left running with its indicator lit.
        guard !isCapturing else {
            completion(.failure(CameraError.captureInProgress))
            return
        }

        isCapturing = true
        self.maxPhotos = maxPhotos
        self.completion = completion

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            captureAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.captureAuthorized() : self?.finish(.failure(CameraError.permissionDenied))
                }
            }
        case .denied, .restricted:
            finish(.failure(CameraError.permissionDenied))
        @unknown default:
            finish(.failure(CameraError.permissionDenied))
        }
    }

    private func captureAuthorized() {
        do {
            let session = AVCaptureSession()
            session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(for: .video) else {
                throw CameraError.noCamera
            }

            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCapturePhotoOutput()

            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw CameraError.cannotConfigure
            }

            session.addInput(input)
            session.addOutput(output)

            self.session = session
            self.output = output

            sessionQueue.async {
                session.startRunning()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let settings = AVCapturePhotoSettings()
                    output.capturePhoto(with: settings, delegate: self)
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            Task { @MainActor in
                self.finish(.failure(error))
            }
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            Task { @MainActor in
                self.finish(.failure(CameraError.noPhotoData))
            }
            return
        }

        Task { @MainActor in
            do {
                let url = try self.savePhoto(data)
                try self.prunePhotos(maxPhotos: self.maxPhotos)
                self.finish(.success(url))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    /// Saves a JPEG the caller already has (a face-unlock frame) into the failed-attempts folder.
    func saveExternalPhoto(_ data: Data, maxPhotos: Int) {
        do {
            let url = try savePhoto(data)
            try prunePhotos(maxPhotos: maxPhotos)
            AppLog.write("face miss photo saved: \(url.path)")
        } catch {
            AppLog.write("face miss photo failed: \(error.localizedDescription)")
        }
    }

    private func savePhoto(_ data: Data) throws -> URL {
        let directoryURL = try failedAttemptsDirectory()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let filename = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".jpg"
        let url = directoryURL.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func prunePhotos(maxPhotos: Int) throws {
        let directoryURL = try failedAttemptsDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "jpg" }
        .sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return leftDate > rightDate
        }

        for url in urls.dropFirst(maxPhotos) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func failedAttemptsDirectory() throws -> URL {
        try FailedAttemptStore.directory()
    }

    private func finish(_ result: Result<URL, Error>) {
        if let session {
            sessionQueue.async { session.stopRunning() }
        }
        session = nil
        output = nil
        isCapturing = false
        completion?(result)
        completion = nil
    }
}

struct LockShortcut: Equatable, Codable {
    var keyCode: Int
    var modifiers: Int   // NSEvent.ModifierFlags raw value (device-independent)
    var label: String    // Display character for the key, e.g. "L"

    /// Placeholder for a recorder slot the user added but hasn't typed a combo into yet.
    /// It has no modifier, so `HotKeyCenter` never registers it.
    static let unset = LockShortcut(keyCode: -1, modifiers: 0, label: "")

    var isSet: Bool { keyCode >= 0 && hasModifier }

    /// Same physical combination, ignoring the display label (which can differ per layout).
    func sameKey(as other: LockShortcut) -> Bool {
        other.keyCode == keyCode && other.cocoaModifiers == cocoaModifiers
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifiers)).intersection(.deviceIndependentFlagsMask)
    }

    /// Carbon modifier mask for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        let flags = cocoaModifiers
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var cgModifierFlags: CGEventFlags {
        var result: CGEventFlags = []
        let flags = cocoaModifiers
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        return result
    }

    /// "⌃⌥⌘L" style display string.
    var displayString: String {
        var parts = ""
        let flags = cocoaModifiers
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + label
    }

    var hasModifier: Bool {
        !cocoaModifiers.isEmpty
    }
}

/// Registers the system-wide hot keys via Carbon and fires `action` when one is pressed.
/// Carbon's RegisterEventHotKey works without Accessibility permission and reliably
/// captures the combination even when SoftLock isn't frontmost.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var shortcuts: [LockShortcut] = []
    private var action: ((LockShortcut) -> Void)?
    private var isSuspended = false

    func handleFire(id: UInt32) {
        guard !isSuspended, shortcuts.indices.contains(Int(id)) else { return }
        action?(shortcuts[Int(id)])
    }

    func register(_ shortcuts: [LockShortcut], action: @escaping (LockShortcut) -> Void) {
        self.shortcuts = shortcuts
        self.action = action
        applyRegistration()
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterHotKeys()
        AppLog.write("hotkey suspended")
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        applyRegistration()
        AppLog.write("hotkey resumed")
    }

    func unregister() {
        unregisterHotKeys()
        shortcuts = []
        action = nil
    }

    private func applyRegistration() {
        unregisterHotKeys()
        guard !isSuspended, !shortcuts.isEmpty else { return }
        installHandlerIfNeeded()

        // The hot-key id is the index into `shortcuts`, so `handleFire(id:)` can tell
        // which combination fired. Unset/modifier-less slots keep their index but are
        // never registered.
        for (index, shortcut) in shortcuts.enumerated() {
            guard shortcut.hasModifier else {
                AppLog.write("hotkey skipped: no modifier in shortcut")
                continue
            }
            let hotKeyID = EventHotKeyID(signature: OSType(0x53464C4B), id: UInt32(index)) // 'SFLK'
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                AppLog.write("hotkey registered: \(shortcut.displayString)")
            } else {
                AppLog.write("hotkey register failed status=\(status) for \(shortcut.displayString)")
            }
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let id = hotKeyID.id
            Task { @MainActor in HotKeyCenter.shared.handleFire(id: id) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)
    }
}

/// iPhone-style passcode entry: a row of dot indicators above a numeric keypad.
/// Calls `onComplete` once `length` digits are entered. Works with mouse clicks and
/// the physical number keys.
/// SF Symbol images carry alignment insets that made NSGridView grow the Touch ID / delete keys past the digit size.
final class KeypadKeyButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

@MainActor
final class PINInputView: NSView {
    private let length: Int
    private let usesLightContent: Bool
    private let glassEnabled: Bool
    private let compact: Bool
    private let onTouchID: (() -> Void)?
    private let onComplete: (String) -> Void

    private var digits = "" { didSet { updateDots() } }
    private var dotViews: [NSView] = []
    private var keypadButtons: [NSButton] = []

    // Keypad metrics shrink a notch on small displays so the whole lock layout fits.
    private var buttonSize: CGFloat { compact ? 54 : 64 }
    private var digitFontSize: CGFloat { compact ? 22 : 26 }
    // Sized so the outline glyphs (touchid, delete.left) read at the same optical
    // weight as the digit labels; smaller point sizes look shrunken next to them.
    private var symbolPointSize: CGFloat { compact ? 19 : 22 }
    private var columnSpacing: CGFloat { compact ? 14 : 18 }
    private var rowSpacing: CGFloat { compact ? 11 : 14 }
    private var dotSpacing: CGFloat { compact ? 16 : 18 }
    private var dotsToGridSpacing: CGFloat { compact ? 20 : 26 }
    private var contentWidth: CGFloat { buttonSize * 3 + columnSpacing * 2 }
    private var contentHeight: CGFloat { 14 + dotsToGridSpacing + buttonSize * 4 + rowSpacing * 3 }

    var isEnabled = true {
        didSet { keypadButtons.forEach { $0.isEnabled = isEnabled } }
    }

    init(
        length: Int,
        onDark: Bool,
        glassEnabled: Bool = false,
        compact: Bool = false,
        onTouchID: (() -> Void)? = nil,
        onComplete: @escaping (String) -> Void
    ) {
        self.length = length
        self.usesLightContent = onDark
        self.glassEnabled = glassEnabled
        self.compact = compact
        self.onTouchID = onTouchID
        self.onComplete = onComplete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reset() {
        digits = ""
    }

    private var dotColor: NSColor {
        usesLightContent ? .white : NSColor.black.withAlphaComponent(0.86)
    }

    private var lineColor: NSColor {
        if glassEnabled {
            return usesLightContent ? NSColor.white.withAlphaComponent(0.34) : NSColor.black.withAlphaComponent(0.30)
        }
        return usesLightContent ? NSColor.white.withAlphaComponent(0.5) : NSColor.black.withAlphaComponent(0.34)
    }

    private var keypadBackground: NSColor {
        if glassEnabled {
            return usesLightContent ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.055)
        }
        return usesLightContent ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.72)
    }

    private var keypadShadow: NSColor {
        usesLightContent ? NSColor.black.withAlphaComponent(0.32) : NSColor.black.withAlphaComponent(0.14)
    }

    private func build() {
        let dotsRow = NSStackView()
        dotsRow.orientation = .horizontal
        dotsRow.spacing = dotSpacing
        dotsRow.alignment = .centerY
        for _ in 0..<length {
            let dot = NSView()
            dot.wantsLayer = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer?.cornerRadius = 7
            dot.layer?.borderWidth = 1.5
            dot.layer?.borderColor = dotColor.cgColor
            dot.widthAnchor.constraint(equalToConstant: 14).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 14).isActive = true
            dotViews.append(dot)
            dotsRow.addArrangedSubview(dot)
        }

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = columnSpacing
        grid.xPlacement = .center
        // Default row alignment is first-baseline: a symbol button has no text baseline, so its
        // row drifted against the digit rows. Centre every cell on its own instead.
        grid.yPlacement = .center
        grid.rowAlignment = .none

        let layout = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete"]
        var rowViews: [NSView] = []
        for label in layout {
            switch label {
            case "":
                // The empty bottom-left cell hosts Touch ID when available, so it sits at the
                // same size as the keypad keys instead of taking a separate row below.
                if onTouchID != nil {
                    rowViews.append(makeKeypadButton(symbol: "touchid", symbolDescription: "Touch ID", action: #selector(touchIDTapped)))
                } else {
                    rowViews.append(spacerMatchingKey())
                }
            case "delete":
                rowViews.append(makeKeypadButton(symbol: "delete.left", symbolDescription: "Delete", action: #selector(deleteTapped)))
            default:
                rowViews.append(makeDigitButton(label))
            }
            if rowViews.count == 3 {
                grid.addRow(with: rowViews)
                rowViews = []
            }
        }

        let stack = NSStackView(views: [dotsRow, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = dotsToGridSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: contentWidth),
            heightAnchor.constraint(equalToConstant: contentHeight),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
        updateDots()
    }

    private func makeDigitButton(_ digit: String) -> NSButton {
        let button = makeKeypadButton(title: digit, action: #selector(digitTapped(_:)))
        button.tag = Int(digit) ?? 0
        return button
    }

    private func makeKeypadButton(title: String? = nil, symbol: String? = nil, symbolDescription: String? = nil, action: Selector) -> NSButton {
        let button = KeypadKeyButton(title: title ?? "", target: self, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.bezelStyle = .regularSquare
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        button.layer?.cornerRadius = buttonSize / 2
        button.layer?.cornerCurve = .continuous
        button.layer?.borderWidth = glassEnabled ? 1.15 : 1
        button.layer?.borderColor = lineColor.cgColor
        button.layer?.backgroundColor = keypadBackground.cgColor
        button.layer?.shadowColor = keypadShadow.cgColor
        button.layer?.shadowOpacity = glassEnabled ? 1 : 0
        button.layer?.shadowRadius = glassEnabled ? 14 : 0
        button.layer?.shadowOffset = CGSize(width: 0, height: -7)
        button.contentTintColor = dotColor
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbolDescription)?
                .withSymbolConfiguration(config)
        } else {
            button.attributedTitle = NSAttributedString(
                string: title ?? "",
                attributes: [
                    .font: NSFont.systemFont(ofSize: digitFontSize, weight: .regular),
                    .foregroundColor: dotColor
                ]
            )
        }
        keypadButtons.append(button)
        return button
    }

    /// Invisible placeholder the exact size of a key, so the grid columns stay aligned when
    /// the bottom-left cell isn't a Touch ID button.
    private func spacerMatchingKey() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        spacer.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        return spacer
    }

    @objc private func touchIDTapped() {
        guard isEnabled else { return }
        onTouchID?()
    }

    @objc private func digitTapped(_ sender: NSButton) {
        append(String(sender.tag))
    }

    @objc private func deleteTapped() {
        guard isEnabled, !digits.isEmpty else { return }
        digits.removeLast()
    }

    private func append(_ digit: String) {
        guard isEnabled, digits.count < length else { return }
        digits += digit
        if digits.count == length {
            let value = digits
            onComplete(value)
        }
    }

    private func updateDots() {
        for (index, dot) in dotViews.enumerated() {
            dot.layer?.backgroundColor = index < digits.count ? dotColor.cgColor : NSColor.clear.cgColor
        }
    }

    /// Whether any digit has been entered; the lock screen checks it before treating Space as the
    /// face-scan shortcut.
    var hasInput: Bool { !digits.isEmpty }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 51 { // Backspace
            deleteTapped()
            return
        }
        // Append the single matched digit, not the whole string: a multi-character
        // `charactersIgnoringModifiers` would overshoot `length`, and the
        // `digits.count == length` completion check would then never fire.
        if let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first,
           ("0"..."9").contains(Character(scalar)) {
            append(String(Character(scalar)))
            return
        }
        super.keyDown(with: event)
    }
}

/// A small native control that records a keyboard shortcut. Click to start recording,
/// then press the desired combination (a modifier is required). Esc cancels.
@MainActor
final class ShortcutRecorderView: NSView {
    private(set) var shortcut: LockShortcut
    private let label = NSTextField(labelWithString: "")
    var glassEnabled = false {
        didSet { updateAppearance() }
    }
    private var recording = false {
        didSet {
            updateAppearance()
            if oldValue != recording {
                onRecordingChange?(recording)
            }
        }
    }
    var onChange: ((LockShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    init(shortcut: LockShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// Border/background are resolved to fixed CGColors, so re-resolve on light/dark change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { updateAppearance() }
    }

    func update(_ shortcut: LockShortcut) {
        self.shortcut = shortcut
        recording = false
    }

    /// Puts the control straight into recording mode, as if it had been clicked.
    func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        recording.toggle()
        if recording {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // Esc
            recording = false
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !mods.intersection([.command, .option, .control]).isEmpty else {
            NSSound.beep() // require at least one of ⌃⌥⌘ so the hotkey is global-safe
            return
        }

        let typed = (event.charactersIgnoringModifiers ?? "").uppercased()
        let display = Self.keyLabel(keyCode: Int(event.keyCode), fallback: typed)
        shortcut = LockShortcut(keyCode: Int(event.keyCode), modifiers: Int(mods.rawValue), label: display)
        onChange?(shortcut)
        recording = false
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    private func updateAppearance() {
        if recording {
            label.stringValue = "Type shortcut…"
        } else {
            label.stringValue = shortcut.isSet ? shortcut.displayString : "Click to record"
        }
        label.textColor = (recording || !shortcut.isSet) ? .secondaryLabelColor : .labelColor
        if glassEnabled {
            layer?.borderColor = (recording ? NSColor.controlAccentColor.withAlphaComponent(0.72) : NSColor.white.withAlphaComponent(0.32)).cgColor
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.42).cgColor
            layer?.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
            layer?.shadowOpacity = 1
            layer?.shadowRadius = 10
            layer?.shadowOffset = CGSize(width: 0, height: -5)
        } else {
            layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            layer?.shadowOpacity = 0
        }
    }

    private static func keyLabel(keyCode: Int, fallback: String) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 53: return "⎋"
        default:
            let trimmed = fallback.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Key \(keyCode)" : trimmed
        }
    }
}

private enum BiometricAuth {
    /// True when this Mac has Touch ID (built-in or Magic Keyboard) enrolled and usable.
    static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return canEvaluate && context.biometryType == .touchID
    }

    /// Presents the system Touch ID sheet. `completion` is always called on the main actor.
    static func evaluate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "Use Password"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            AppLog.write("biometrics unavailable: \(error?.localizedDescription ?? "unknown")")
            Task { @MainActor in completion(false) }
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
            if let evalError {
                AppLog.write("biometric evaluate result success=\(success) error=\(evalError.localizedDescription)")
            }
            Task { @MainActor in completion(success) }
        }
    }
}

private enum FailedAttemptStore {
    static func directory() throws -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = baseURL
            .appendingPathComponent(appIdentifier, isDirectory: true)
            .appendingPathComponent("failed-attempts", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// The most recent capture files, newest first, for the Settings preview strip.
    static func recentPhotos(limit: Int) -> [URL] {
        guard let directoryURL = try? directory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: [.creationDateKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return Array(
            urls
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { left, right in
                    let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return leftDate > rightDate
                }
                .prefix(limit)
        )
    }
}

/// Removes everything SoftLock writes to Application Support: the passcode record, logs,
/// failed-attempt photos and imported backgrounds.
private enum SoftLockData {
    static func eraseStoredFiles() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directories = [
            base.appendingPathComponent(appIdentifier, isDirectory: true),
            base.appendingPathComponent("SoftLock", isDirectory: true)
        ]
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Persists a marker on disk while the lock screen is engaged. If SoftLock crashes or is
/// force-quit while locked and then relaunches (e.g. via launchd KeepAlive), the marker
/// tells it to re-lock immediately instead of dropping the user onto an open desktop.
///
/// The marker is cleared on *any* unlock — a passcode/recovery unlock or a trusted
/// macOS-login standdown — so it never strands the app in a locked loop.
private enum LockState {
    private static func markerURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(appIdentifier, isDirectory: true)
            .appendingPathComponent("locked", isDirectory: false)
    }

    static func mark() {
        let url = markerURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    static func clear() {
        try? FileManager.default.removeItem(at: markerURL())
    }

    static var isMarked: Bool {
        FileManager.default.fileExists(atPath: markerURL().path)
    }
}

/// Revokes SoftLock's privacy permission grants via `tccutil`, so the next install isn't
/// blocked by a stale grant tied to an old code signature.
private enum PermissionsReset {
    static func resetAll() {
        let identifiers = Set([appIdentifier, Bundle.main.bundleIdentifier].compactMap { $0 })
        for identifier in identifiers {
            run(["reset", "All", identifier])
        }
    }

    private static func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.write("tccutil \(arguments.joined(separator: " ")) failed: \(error.localizedDescription)")
        }
    }
}

private enum CameraError: LocalizedError {
    case permissionDenied
    case noCamera
    case cannotConfigure
    case noPhotoData
    case captureInProgress

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Camera permission is not granted."
        case .noCamera:
            "No camera is available."
        case .cannotConfigure:
            "Camera session could not be configured."
        case .noPhotoData:
            "Camera did not return photo data."
        case .captureInProgress:
            "A failed-attempt photo is already being captured."
        }
    }
}

private struct PasswordRecord: Codable {
    let passwordSalt: Data
    let passwordHash: Data
    let recoverySalt: Data
    let recoveryHash: Data
    let iterations: Int
}

private final class PasswordStore {
    private let iterations = 120_000
    private let fileURL: URL

    var hasPassword: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    var isConfigured: Bool {
        loadRecord() != nil
    }

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = baseURL.appendingPathComponent(appIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("password.json")
    }

    func save(password: String) throws -> String {
        let passwordSalt = try randomBytes(count: 32)
        let recoverySalt = try randomBytes(count: 32)
        let recoveryCode = try makeRecoveryCode()
        let record = PasswordRecord(
            passwordSalt: passwordSalt,
            passwordHash: hash(credential: password, salt: passwordSalt, iterations: iterations),
            recoverySalt: recoverySalt,
            recoveryHash: hash(credential: recoveryCode, salt: recoverySalt, iterations: iterations),
            iterations: iterations
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return recoveryCode
    }

    func verify(credential: String) -> CredentialResult {
        guard let record = loadRecord() else {
            return .invalid
        }

        let passwordHash = hash(credential: credential, salt: record.passwordSalt, iterations: record.iterations)
        if constantTimeEquals(passwordHash, record.passwordHash) {
            return .password
        }

        let recoveryHash = hash(credential: credential.uppercased(), salt: record.recoverySalt, iterations: record.iterations)
        if constantTimeEquals(recoveryHash, record.recoveryHash) {
            return .recovery
        }

        return .invalid
    }

    func delete() throws {
        guard hasPassword else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func deleteIfUnreadable() {
        guard hasPassword, loadRecord() == nil else { return }
        try? delete()
    }

    private func loadRecord() -> PasswordRecord? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let record = try? JSONDecoder().decode(PasswordRecord.self, from: data)
        else {
            return nil
        }

        return record
    }

    private func makeRecoveryCode() throws -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = try randomBytes(count: 20)
        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: characters.count, by: 5)
            .map { String(characters[$0..<min($0 + 5, characters.count)]) }
            .joined(separator: "-")
    }

    private func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw PasswordError.randomBytesFailed }
        return Data(bytes)
    }

    private func hash(credential: String, salt: Data, iterations: Int) -> Data {
        let credentialData = Data(credential.utf8)
        var digest = Data(SHA256.hash(data: salt + credentialData))

        for _ in 1..<iterations {
            digest = Data(SHA256.hash(data: digest + salt + credentialData))
        }

        return digest
    }

    private func constantTimeEquals(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0

        for index in left.indices {
            difference |= left[index] ^ right[index]
        }

        return difference == 0
    }
}

private enum PasswordError: LocalizedError {
    case randomBytesFailed

    var errorDescription: String? {
        "Couldn't generate secure random data."
    }
}

private enum AppLog {
    static func write(_ message: String) {
        let directoryURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let line = "[\(Date())] \(message)\n"
        let fileURL = directoryURL.appendingPathComponent("softlock.log")

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private enum LockIcon {
    static func make() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "SoftLock")?
            .withSymbolConfiguration(config) {
            symbol.isTemplate = true
            return symbol
        }

        // Fallback for older systems without the SF Symbol.
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setStroke()
        let shackle = NSBezierPath()
        shackle.lineWidth = 2
        shackle.appendArc(withCenter: NSPoint(x: 9, y: 10), radius: 5, startAngle: 0, endAngle: 180, clockwise: false)
        shackle.stroke()
        let body = NSBezierPath(roundedRect: NSRect(x: 4, y: 3, width: 10, height: 8), xRadius: 2, yRadius: 2)
        body.lineWidth = 2
        body.stroke()
        image.unlockFocus()
        return image
    }
}
