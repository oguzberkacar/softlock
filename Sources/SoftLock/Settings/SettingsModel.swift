//
//  SettingsModel.swift
//
//  The one object the Settings window reads and writes. It fronts AppSettings,
//  FaceUnlockSettings, the updater, the permission checks and the stores, so the SwiftUI
//  panes stay declarative: every row binds to a property here, and every button calls a method
//  here. Properties are computed straight from the stores (no shadow copies to keep in sync);
//  setters announce the change so the views refresh.
//

import AppKit
import AVFoundation
import SoftLockCore
import LocalAuthentication
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    enum Pane: String, CaseIterable, Identifiable {
        case general
        case lockScreen
        case unlock
        case privacy
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .lockScreen: return "Lock Screen"
            case .unlock: return "Unlock"
            case .privacy: return "Privacy"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .lockScreen: return "lock.display"
            case .unlock: return "touchid"
            case .privacy: return "hand.raised.fill"
            case .about: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return Color(nsColor: .systemGray)
            case .lockScreen: return Color(nsColor: .black)
            case .unlock: return Color(nsColor: .systemGreen)
            case .privacy: return Color(nsColor: .systemBlue)
            case .about: return Color(nsColor: .systemTeal)
            }
        }
    }

    struct Camera: Identifiable, Equatable {
        let id: String
        let name: String
    }

    struct FaceStatus {
        let modelAvailable: Bool
        let enrolled: Bool
        let enrolledAt: Date?
        let cameraAuthorization: AVAuthorizationStatus
    }

    /// Sentinel for "Automatic" in the display and camera pickers.
    static let automaticChoice = ""

    private let settings: AppSettings
    private let onLock: () -> Void
    private let onChangePasscode: () -> Void
    private let onDeleteApp: () -> Void
    /// The window that hosts the panes; sheets (file panel, wallpaper picker) attach to it.
    weak var hostWindow: NSWindow?
    private var wallpaperPicker: WallpaperPickerWindowController?
    private var enrollment: FaceEnrollmentWindowController?

    @Published var selection: Pane = .general
    /// Cached because `LAContext` is not free and the Unlock pane reads it on every redraw.
    @Published private(set) var touchIDAvailable = false
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var recentPhotos: [URL] = []
    @Published private(set) var permissions: [PermissionStatus] = []
    @Published private(set) var displayNames: [String] = []
    @Published private(set) var cameras: [Camera] = []
    @Published private(set) var face = FaceStatus(modelAvailable: false, enrolled: false, enrolledAt: nil, cameraAuthorization: .notDetermined)
    @Published private(set) var mediaImportError: String?

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
        refresh()
    }

    /// Re-reads everything that can change behind the window's back: permission grants,
    /// connected displays and cameras, the enrolled face, captured photos.
    func refresh() {
        objectWillChange.send()
        touchIDAvailable = BiometricAuth.isAvailable
        recentPhotos = FailedAttemptStore.recentPhotos(limit: 3)
        displayNames = NSScreen.screens.map(\.localizedName)
        cameras = FaceCameraFeed.availableDevices().map { Camera(id: $0.uniqueID, name: $0.localizedName) }
        let enrolled = FaceUnlockStore.hasProfile
        face = FaceStatus(
            modelAvailable: ArcFaceEmbedder.isModelAvailable,
            enrolled: enrolled,
            enrolledAt: enrolled ? FaceUnlockStore.profileModifiedAt : nil,
            cameraAuthorization: FaceCameraFeed.authorizationStatus
        )
        // Face unlock cannot stay on without a face to compare against.
        if !enrolled, FaceUnlockSettings.shared.isEnabled {
            FaceUnlockSettings.shared.isEnabled = false
        }
        refreshPermissions()
    }

    private func refreshPermissions() {
        // Screen Recording is only used to sample the desktop for Auto input appearance over a
        // see-through background — mirror exactly that condition (see sampleScreenBrightness).
        let screenRecordingRequired = settings.inputAppearanceMode == .auto
            && (settings.backgroundEffectKind == .transparent || settings.backgroundEffectKind == .blur)
        // Both camera features need the grant, not just failed-attempt photos.
        let cameraRequired = settings.capturePhotoOnFailure || FaceUnlockSettings.shared.isEnabled
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        permissions = [
            PermissionStatus(
                name: "Accessibility",
                kind: .accessibility,
                ok: AXIsProcessTrusted(),
                required: true,
                detail: "Blocks keyboard shortcuts and app switching while locked."
            ),
            PermissionStatus(
                name: "Screen Recording",
                kind: .screenRecording,
                ok: !screenRecordingRequired || CGPreflightScreenCaptureAccess(),
                required: screenRecordingRequired,
                detail: "Samples the desktop so Auto appearance can pick light or dark controls over a transparent or blurred background."
            ),
            PermissionStatus(
                name: "Camera",
                kind: .camera,
                ok: !cameraRequired || cameraStatus == .authorized,
                required: cameraRequired,
                detail: cameraRequired ? "Used by face unlock and failed-attempt photos; \(cameraStatus.permissionDetail)." : "Only needed for face unlock or failed-attempt photos."
            )
        ]
    }

    // MARK: - General

    var launchAtLoginStatus: SMAppService.Status { settings.launchAtLoginStatus }

    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }
        set {
            objectWillChange.send()
            launchAtLoginError = nil
            do {
                try settings.setLaunchAtLoginEnabled(newValue)
            } catch {
                launchAtLoginError = "Couldn't update Login Items"
                AppLog.write("launch at login update failed: \(error.localizedDescription)")
            }
        }
    }

    var launchAtLoginUnavailableReason: String { settings.launchAtLoginUnavailableReason }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        objectWillChange.send()
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    var shortcuts: [LockShortcut] { settings.lockShortcuts }

    /// Returns false (and leaves the stored shortcuts alone) when the combo is already taken by
    /// another slot; the recorder reverts to what it showed before.
    @discardableResult
    func setShortcut(_ shortcut: LockShortcut, at index: Int) -> Bool {
        var all = settings.lockShortcuts
        guard all.indices.contains(index) else { return false }
        objectWillChange.send()
        if all.enumerated().contains(where: { $0.offset != index && $0.element.sameKey(as: shortcut) }) {
            NSSound.beep()
            return false
        }
        all[index] = shortcut
        settings.lockShortcuts = all
        return true
    }

    func addShortcut() {
        var all = settings.lockShortcuts
        // Reuse a still-unset slot instead of stacking empty ones.
        guard !all.contains(where: { !$0.isSet }) else { return }
        objectWillChange.send()
        all.append(.unset)
        settings.lockShortcuts = all
    }

    func removeShortcut(at index: Int) {
        var all = settings.lockShortcuts
        guard all.indices.contains(index) else { return }
        objectWillChange.send()
        all.remove(at: index)
        settings.lockShortcuts = all
    }

    var automaticUpdates: Bool {
        get { UpdaterController.shared.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            UpdaterController.shared.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    func lockNow() {
        hostWindow?.close()
        onLock()
    }

    // MARK: - Lock screen

    var lockTitle: String {
        get { settings.lockTitle }
        set {
            objectWillChange.send()
            settings.lockTitle = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var backgroundKind: BackgroundEffectKind {
        get { settings.backgroundEffectKind }
        set {
            objectWillChange.send()
            settings.backgroundEffectKind = newValue
            refreshPermissions()
        }
    }

    var blurLevel: Double {
        get { settings.blurLevel }
        set {
            objectWillChange.send()
            settings.blurLevel = newValue
        }
    }

    var backgroundColorID: String {
        get { settings.backgroundColorID }
        set {
            objectWillChange.send()
            settings.backgroundColorID = newValue
        }
    }

    var hasBackgroundMedia: Bool { settings.backgroundMediaURL != nil }
    var backgroundMediaName: String { settings.backgroundMediaDisplayName }

    func chooseBackgroundMedia() {
        openBackgroundMediaPanel(startingAt: nil, showsHiddenFiles: false)
    }

    func chooseAppleWallpaper() {
        let assets = SystemWallpaperLibrary.assets()
        guard !assets.isEmpty else {
            openBackgroundMediaPanel(
                startingAt: URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
                showsHiddenFiles: true
            )
            return
        }
        guard let hostWindow else { return }
        let picker = WallpaperPickerWindowController(assets: assets) { [weak self] asset in
            self?.importBackgroundMedia(from: asset.sourceURL)
        }
        wallpaperPicker = picker
        hostWindow.beginSheet(picker.window) { [weak self] _ in
            self?.wallpaperPicker = nil
        }
    }

    func clearBackgroundMedia() {
        objectWillChange.send()
        settings.clearBackgroundMedia()
        mediaImportError = nil
    }

    private func openBackgroundMediaPanel(startingAt directoryURL: URL?, showsHiddenFiles: Bool) {
        guard let hostWindow else { return }
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
        panel.beginSheetModal(for: hostWindow) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importBackgroundMedia(from: url)
        }
    }

    private func importBackgroundMedia(from url: URL) {
        objectWillChange.send()
        do {
            try settings.storeBackgroundMedia(from: url)
            settings.backgroundEffectKind = .media
            mediaImportError = nil
        } catch {
            mediaImportError = "Couldn't load \(url.lastPathComponent)."
            AppLog.write("background media import failed: \(error.localizedDescription)")
        }
        refreshPermissions()
    }

    var inputAppearance: InputAppearanceMode {
        get { settings.inputAppearanceMode }
        set {
            objectWillChange.send()
            settings.inputAppearanceMode = newValue
            refreshPermissions()
        }
    }

    var liquidGlassInputs: Bool {
        get { settings.liquidGlassInputsEnabled }
        set {
            objectWillChange.send()
            settings.liquidGlassInputsEnabled = newValue
        }
    }

    /// Picker value: `automaticChoice`, or a display's localized name.
    var unlockDisplayChoice: String {
        get { settings.unlockDisplayName ?? Self.automaticChoice }
        set {
            objectWillChange.send()
            settings.unlockDisplayName = newValue == Self.automaticChoice ? nil : newValue
        }
    }

    /// The stored display plus everything connected, so a chosen-but-unplugged display still
    /// shows (marked) instead of silently snapping back to Automatic.
    var displayChoices: [String] {
        var names = displayNames
        if let stored = settings.unlockDisplayName, !names.contains(stored) {
            names.append(stored)
        }
        return names
    }

    func isDisplayConnected(_ name: String) -> Bool {
        displayNames.contains(name)
    }

    // MARK: - Unlock

    var passcodeDescription: String {
        switch settings.unlockStyle {
        case .pin: return "\(settings.pinLength)-digit PIN"
        case .password: return "Password"
        }
    }

    func changePasscode() {
        hostWindow?.close()
        onChangePasscode()
    }

    var useTouchID: Bool {
        get { settings.useTouchID && touchIDAvailable }
        set {
            objectWillChange.send()
            settings.useTouchID = newValue
        }
    }

    var touchIDKey: TouchIDTriggerKey {
        get { settings.touchIDTriggerKey }
        set {
            objectWillChange.send()
            settings.touchIDTriggerKey = newValue
        }
    }

    var touchIDPromptOnLock: Bool {
        get { settings.touchIDPromptOnLock }
        set {
            objectWillChange.send()
            settings.touchIDPromptOnLock = newValue
        }
    }

    var faceEnabled: Bool {
        get { FaceUnlockSettings.shared.isEnabled }
        set {
            objectWillChange.send()
            guard newValue else {
                FaceUnlockSettings.shared.isEnabled = false
                FaceUnlockController.shared.reset()
                refreshPermissions()
                return
            }
            Task { [weak self] in
                // Ask for camera permission here, in Settings, where the system prompt is visible.
                let granted = await FaceCameraFeed.requestAccess()
                guard let self else { return }
                FaceUnlockSettings.shared.isEnabled = granted
                self.refresh()
            }
        }
    }

    var faceAutoScan: Bool {
        get { FaceUnlockSettings.shared.autoScanOnLock }
        set {
            objectWillChange.send()
            FaceUnlockSettings.shared.autoScanOnLock = newValue
        }
    }

    var faceLiveness: LivenessMode {
        get { FaceUnlockSettings.shared.livenessMode }
        set {
            objectWillChange.send()
            FaceUnlockSettings.shared.livenessMode = newValue
        }
    }

    /// Picker value: `automaticChoice`, or a camera's `uniqueID`.
    var faceCameraChoice: String {
        get { FaceUnlockSettings.shared.cameraUniqueID ?? Self.automaticChoice }
        set {
            objectWillChange.send()
            FaceUnlockSettings.shared.cameraUniqueID = newValue == Self.automaticChoice ? nil : newValue
        }
    }

    var faceCameraChoices: [Camera] {
        var all = cameras
        if let stored = FaceUnlockSettings.shared.cameraUniqueID, !all.contains(where: { $0.id == stored }) {
            all.append(Camera(id: stored, name: "Disconnected camera"))
        }
        return all
    }

    var keepScanPhotos: Bool {
        get { FaceUnlockSettings.shared.keepScanPhotos }
        set {
            objectWillChange.send()
            FaceUnlockSettings.shared.keepScanPhotos = newValue
        }
    }

    var storedScanCount: Int { FaceScanLog.count }

    func reviewScans() {
        FaceScanReviewWindowController.present(onChange: { [weak self] in self?.refresh() })
    }

    var faceMaxFailures: Int { FaceUnlockThrottle.defaultMaxFailures }

    func enrollFace() {
        guard enrollment == nil else { return }
        let controller = FaceEnrollmentWindowController { [weak self] _ in
            self?.enrollment = nil
            self?.refresh()
        }
        enrollment = controller
        controller.show()
    }

    func testFace() {
        FaceRecognitionTestWindowController.present()
    }

    func deleteFace() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete your face data?"
        alert.informativeText = "This removes the enrolled face signature and its encryption key from this Mac and turns face unlock off. Your passcode is not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FaceUnlockSettings.shared.isEnabled = false
        FaceUnlockController.shared.reset()
        FaceUnlockStore.eraseAll()
        refresh()
    }

    // MARK: - Privacy

    var capturePhotoOnFailure: Bool {
        get { settings.capturePhotoOnFailure }
        set {
            objectWillChange.send()
            settings.capturePhotoOnFailure = newValue
            refreshPermissions()
        }
    }

    var maxFailedAttemptPhotos: Int {
        get { settings.maxFailedAttemptPhotos }
        set {
            objectWillChange.send()
            settings.maxFailedAttemptPhotos = newValue
        }
    }

    var failedAttemptsFolderPath: String {
        (try? FailedAttemptStore.directory().path) ?? "~/Library/Application Support/\(FaceUnlockPaths.appIdentifier)/failed-attempts"
    }

    func openFailedAttemptsFolder() {
        do {
            NSWorkspace.shared.open(try FailedAttemptStore.directory())
        } catch {
            AppLog.write("failed attempts folder open failed: \(error.localizedDescription)")
        }
    }

    func openPhoto(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func grant(_ kind: PermissionKind) {
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
                Task { [weak self] in
                    _ = await FaceCameraFeed.requestAccess()
                    self?.refresh()
                }
            } else {
                openPrivacyPane(kind)
            }
        }
        refresh()
    }

    private func openPrivacyPane(_ kind: PermissionKind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.privacyAnchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - About

    var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    var changelog: [Changelog.Entry] { Changelog.entries }

    func resetAllSettings() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Lock screen appearance, shortcuts, Touch ID and face unlock options go back to their defaults. Your passcode and enrolled face are kept."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        objectWillChange.send()
        settings.lockTitle = AppSettings.defaultLockTitle
        settings.backgroundEffectKind = .blur
        settings.blurLevel = AppSettings.defaultBlurLevel
        settings.backgroundColorID = LockBackgroundSwatch.defaultID
        settings.clearBackgroundMedia()
        settings.inputAppearanceMode = .auto
        settings.liquidGlassInputsEnabled = false
        settings.unlockDisplayName = nil
        settings.lockShortcuts = [AppSettings.defaultShortcut]
        settings.useTouchID = BiometricAuth.isAvailable
        settings.touchIDPromptOnLock = false
        settings.capturePhotoOnFailure = false
        settings.maxFailedAttemptPhotos = AppSettings.defaultMaxFailedAttemptPhotos
        FaceUnlockSettings.shared.isEnabled = false
        FaceUnlockSettings.shared.autoScanOnLock = false
        FaceUnlockSettings.shared.livenessMode = .light
        FaceUnlockSettings.shared.cameraUniqueID = nil
        FaceUnlockSettings.shared.keepScanPhotos = false
        settings.touchIDTriggerKey = .returnKey
        FaceUnlockController.shared.reset()
        refresh()
    }

    func deleteApp() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete SoftLock?"
        alert.informativeText = "This erases your passcode, settings and face data and revokes SoftLock's macOS permissions (Accessibility, Screen Recording, Camera). SoftLock will quit. You can re-grant permissions next time you launch it.\n\nThis can't be undone."
        alert.addButton(withTitle: "Delete & Quit")
        alert.addButton(withTitle: "Cancel")
        if let cancel = alert.buttons.last {
            alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hostWindow?.close()
        onDeleteApp()
    }
}
