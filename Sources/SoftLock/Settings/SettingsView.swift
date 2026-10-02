//
//  SettingsView.swift
//
//  The settings panes, built the way System Settings builds its own: a sidebar of coloured
//  icon tiles and, per pane, a grouped form of inset cards with the label on the left and the
//  control on the right, section headers above and explanatory footers below. SwiftUI's
//  grouped form style *is* the System Settings look, so none of it is hand-drawn.
//

import AppKit
import ServiceManagement
import SoftLockCore
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsModel.Pane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    PaneIcon(pane: pane)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                .frame(minWidth: 440)
        }
    }

    /// The list wants an optional; a nil selection (clicking empty sidebar space) keeps the
    /// current pane rather than blanking the detail.
    private var selection: Binding<SettingsModel.Pane?> {
        Binding(
            get: { model.selection },
            set: { if let pane = $0 { model.selection = pane } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .general: GeneralPane(model: model)
        case .lockScreen: LockScreenPane(model: model)
        case .unlock: UnlockPane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}

/// The rounded, tinted square System Settings uses for sidebar icons.
private struct PaneIcon: View {
    let pane: SettingsModel.Pane

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(pane.tint)
            Image(systemName: pane.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Lock this Mac") {
                    Button("Lock Now") { model.lockNow() }
                }
            } footer: {
                Text("Agents and background jobs keep running behind the lock screen.")
            }

            Section {
                Toggle("Open at Login", isOn: $model.launchAtLogin)
                    .disabled(model.launchAtLoginStatus == .notFound)
                loginItemsStatusRow
            } header: {
                Text("Startup")
            }

            Section {
                ForEach(Array(model.shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    HStack(spacing: 8) {
                        Text(index == 0 ? "Lock shortcut" : "Alternate shortcut")
                        Spacer(minLength: 12)
                        ShortcutRecorder(
                            shortcut: shortcut,
                            recordOnAppear: !shortcut.isSet,
                            onChange: { model.setShortcut($0, at: index) }
                        )
                        .frame(width: 160, height: 28)
                        if model.shortcuts.count > 1 {
                            Button {
                                model.removeShortcut(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this shortcut")
                        }
                    }
                }
                LabeledContent("Add another shortcut") {
                    Button("Add") { model.addShortcut() }
                        .disabled(model.shortcuts.contains { !$0.isSet })
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Shortcuts work anywhere, even when SoftLock isn't in front. Add an alternate combo for a keyboard with a different layout.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $model.automaticUpdates)
                LabeledContent("SoftLock \(model.version)") {
                    Button("Check for Updates…") { model.checkForUpdates() }
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text("Updates are verified before they are unpacked and nothing installs until you agree.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var loginItemsStatusRow: some View {
        switch model.launchAtLoginStatus {
        case .requiresApproval:
            LabeledContent {
                Button("Open Login Items…") { model.openLoginItemsSettings() }
            } label: {
                Text("Needs your approval in Login Items")
                    .foregroundStyle(.orange)
            }
        case .notFound:
            LabeledContent {
                Button("Show in Finder") { model.revealApp() }
            } label: {
                Text(model.launchAtLoginUnavailableReason)
                    .foregroundStyle(.secondary)
            }
        default:
            if let error = model.launchAtLoginError {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $model.lockTitle, prompt: Text(AppSettings.defaultLockTitle))
                    .multilineTextAlignment(.trailing)
            } header: {
                Text("Text")
            } footer: {
                Text("Shown above the passcode. Leave empty for \u{201C}\(AppSettings.defaultLockTitle)\u{201D}.")
            }

            Section {
                Picker("Style", selection: $model.backgroundKind) {
                    ForEach(BackgroundEffectKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                switch model.backgroundKind {
                case .blur:
                    LabeledContent("Blur amount") {
                        HStack(spacing: 10) {
                            Slider(value: $model.blurLevel, in: 0...1)
                                .frame(width: 180)
                            Text("\(Int((model.blurLevel * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                case .color:
                    LabeledContent("Color") {
                        ColorSwatches(selectedID: $model.backgroundColorID)
                    }
                case .media:
                    LabeledContent("Image or video") {
                        HStack(spacing: 8) {
                            Text(model.hasBackgroundMedia ? model.backgroundMediaName : "None")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .trailing)
                            Button("Choose…") { model.chooseBackgroundMedia() }
                            Button("Apple Wallpapers…") { model.chooseAppleWallpaper() }
                            Button("Clear") { model.clearBackgroundMedia() }
                                .disabled(!model.hasBackgroundMedia)
                        }
                    }
                    if let error = model.mediaImportError {
                        Text(error).foregroundStyle(.red)
                    }
                case .transparent:
                    EmptyView()
                }
            } header: {
                Text("Background")
            } footer: {
                Text(backgroundFootnote)
            }

            Section {
                Picker("Controls", selection: $model.inputAppearance) {
                    ForEach(InputAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Liquid glass inputs", isOn: $model.liquidGlassInputs)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Auto picks light or dark controls from what is behind them. Over a transparent or blurred background that means sampling the display, which needs Screen Recording access.")
            }

            Section {
                Picker("Show passcode on", selection: $model.unlockDisplayChoice) {
                    Text("Automatic").tag(SettingsModel.automaticChoice)
                    ForEach(model.displayChoices, id: \.self) { name in
                        Text(model.isDisplayConnected(name) ? name : "\(name) (not connected)").tag(name)
                    }
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("Automatic uses the display under the pointer, or the built-in display when face unlock looks through the built-in camera. While locked, click any display to move the passcode there.")
            }
        }
        .formStyle(.grouped)
    }

    private var backgroundFootnote: String {
        switch model.backgroundKind {
        case .transparent: return "The desktop stays visible behind the lock screen."
        case .blur: return "Frosts the desktop; 0% leaves it clear."
        case .color: return "A solid colour hides everything on screen."
        case .media: return "An image or video of your own, or one of the macOS wallpapers. The file is copied into SoftLock's support folder."
        }
    }
}

private struct ColorSwatches: View {
    @Binding var selectedID: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LockBackgroundSwatch.all, id: \.id) { swatch in
                let selected = swatch.id == selectedID
                Circle()
                    .fill(Color(nsColor: swatch.color))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle().strokeBorder(
                            selected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: selected ? 2 : 1
                        )
                    )
                    .contentShape(Circle())
                    .onTapGesture { selectedID = swatch.id }
                    .help(swatch.title)
                    .accessibilityLabel(swatch.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Unlock

private struct UnlockPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Passcode") {
                    HStack(spacing: 8) {
                        Text(model.passcodeDescription).foregroundStyle(.secondary)
                        Button("Change…") { model.changePasscode() }
                    }
                }
            } header: {
                Text("Passcode")
            } footer: {
                Text("A password or a 4- or 6-digit PIN. The recovery code you were given at setup always works too.")
            }

            Section {
                Toggle("Unlock with Touch ID", isOn: $model.useTouchID)
                    .disabled(!model.touchIDAvailable)
                Picker("Touch ID key", selection: $model.touchIDKey) {
                    ForEach(TouchIDTriggerKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .disabled(!model.useTouchID)
                Toggle("Open Touch ID automatically when locked", isOn: $model.touchIDPromptOnLock)
                    .disabled(!model.useTouchID)
            } header: {
                Text("Touch ID")
            } footer: {
                Text(model.touchIDAvailable
                    ? "The passcode field is always ready. With the field empty, press the Touch ID key (or tap Use Touch ID) and the fingerprint prompt opens straight away. macOS does not let an app read the sensor without that prompt, so it cannot listen silently. Space is used for face scans when face unlock is on; pick another key unless you want Space for Touch ID."
                    : "This Mac has no Touch ID sensor, or no fingerprint is enrolled in System Settings.")
            }

            Section {
                Toggle("Unlock with Face", isOn: $model.faceEnabled)
                    .disabled(!model.face.modelAvailable || !model.face.enrolled)
                LabeledContent("Face data") {
                    HStack(spacing: 8) {
                        Text(faceDataDescription).foregroundStyle(.secondary)
                        Button(model.face.enrolled ? "Re-enroll…" : "Set Up…") { model.enrollFace() }
                            .disabled(!model.face.modelAvailable)
                        if model.face.enrolled {
                            Button("Test…") { model.testFace() }
                                .disabled(!model.face.modelAvailable)
                            Button("Delete…") { model.deleteFace() }
                        }
                    }
                }
                Picker("Camera", selection: $model.faceCameraChoice) {
                    Text("Automatic").tag(SettingsModel.automaticChoice)
                    ForEach(model.faceCameraChoices) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                }
                .disabled(!model.face.modelAvailable)
                Toggle("Scan automatically when locked", isOn: $model.faceAutoScan)
                    .disabled(!model.faceEnabled)
                Picker("Liveness checks", selection: $model.faceLiveness) {
                    ForEach(LivenessMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!model.faceEnabled)
                Toggle("Keep a photo of every face scan", isOn: $model.keepScanPhotos)
                    .disabled(!model.faceEnabled)
                LabeledContent("Scan history") {
                    HStack(spacing: 8) {
                        Text(model.storedScanCount == 0 ? "Empty" : "\(model.storedScanCount) scans")
                            .foregroundStyle(.secondary)
                        Button("Review…") { model.reviewScans() }
                            .disabled(model.storedScanCount == 0)
                    }
                }
            } header: {
                Text("Face")
            } footer: {
                Text(faceFootnote)
            }
        }
        .formStyle(.grouped)
    }

    private var faceDataDescription: String {
        guard model.face.modelAvailable else { return "Face model not installed" }
        guard model.face.enrolled else { return "Not set up" }
        if let date = model.face.enrolledAt {
            return "Enrolled \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Enrolled"
    }

    private var faceFootnote: String {
        var lines: [String] = []
        if !model.face.modelAvailable {
            lines.append("The face model (ArcFace.mlmodelc) is not installed. Build with scripts/package-app.sh, or copy it to ~/Library/Application Support/\(FaceUnlockPaths.appIdentifier)/.")
        } else if model.face.enrolled, model.face.cameraAuthorization == .denied || model.face.cameraAuthorization == .restricted {
            lines.append("Camera access is off for SoftLock. Allow it in System Settings → Privacy & Security → Camera.")
        } else if model.faceEnabled {
            lines.append(model.faceAutoScan
                ? "The camera starts looking the moment the lock screen appears — walking past the Mac can unlock it right after you lock it."
                : "On the lock screen, press Space or tap the camera button to scan. Recommended if you lock before leaving the desk.")
        }
        switch model.faceLiveness {
        case .off: lines.append("Liveness Off: a printed photo or a phone showing your face can unlock. Least secure.")
        case .light: lines.append("Liveness Light blocks faces that look like a photo or a screen and works while you sit still.")
        case .heavy: lines.append("Liveness Heavy also needs a blink or a slight head turn during the scan; holding still falls back to your passcode.")
        }
        lines.append(model.keepScanPhotos
            ? "Scan history is on: every face scan that sees a face is saved as an encrypted photo on this Mac. Review them, mark the ones that are you, and face unlock learns from those."
            : "Scan history is off. Turn it on to keep an encrypted photo of each scan, review who tried to unlock, and teach face unlock from scans you approve.")
        lines.append("Automatic camera means the built-in camera, or the system default when there is none. Pick an external camera for a MacBook used closed.")
        lines.append("Face unlock is less secure than Touch ID or your passcode: it uses the regular 2D camera and cannot rule out a video or a good mask. After \(model.faceMaxFailures) missed scans it pauses until you unlock another way. Only encrypted face signatures are stored, on this Mac; camera frames are not saved unless you turn on scan history.")
        return lines.joined(separator: " ")
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Capture a photo after a failed unlock", isOn: $model.capturePhotoOnFailure)
                LabeledContent("Photos to keep") {
                    HStack(spacing: 8) {
                        Text("\(model.maxFailedAttemptPhotos)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("Photos to keep", value: $model.maxFailedAttemptPhotos, in: 1...100)
                            .labelsHidden()
                    }
                }
                .disabled(!model.capturePhotoOnFailure)
                recentPhotosRow
            } header: {
                Text("Failed Attempts")
            } footer: {
                Text("Photos are taken with the face unlock camera and kept only on this Mac, in \(model.failedAttemptsFolderPath). Older photos are deleted past the limit.")
            }

            Section {
                ForEach(model.permissions, id: \.name) { permission in
                    PermissionRow(permission: permission) { model.grant(permission.kind) }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility is required: without it macOS lets keyboard shortcuts through the lock screen. Screen Recording and Camera are only needed by the features that use them.")
            }
        }
        .formStyle(.grouped)
    }

    private var recentPhotosRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent photos")
                Spacer()
                Button("Open Folder…") { model.openFailedAttemptsFolder() }
            }
            if model.recentPhotos.isEmpty {
                Text("No photos captured yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 10) {
                    ForEach(model.recentPhotos, id: \.self) { url in
                        Button {
                            model.openPhoto(url)
                        } label: {
                            PhotoThumbnail(url: url)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(url.lastPathComponent)")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PhotoThumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.opacity(0.18)
            }
        }
        .frame(width: 112, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

private struct PermissionRow: View {
    let permission: PermissionStatus
    let grant: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(statusText)
                    .foregroundStyle(statusColor)
                if !permission.ok {
                    Button("Grant…", action: grant)
                }
            }
        } label: {
            Label {
                Text(permission.name)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(statusColor)
            }
            Text(permission.detail)
        }
    }

    private var statusText: String {
        if permission.ok {
            return permission.required ? "Granted" : "Not needed"
        }
        return "Not granted"
    }

    private var statusColor: Color {
        if permission.ok {
            return permission.required ? .green : .secondary
        }
        return .red
    }

    private var symbolName: String {
        if permission.ok {
            return permission.required ? "checkmark.circle.fill" : "minus.circle.fill"
        }
        return "xmark.circle.fill"
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text(versionText).foregroundStyle(.secondary)
                }
                LabeledContent("Updates") {
                    Button("Check for Updates…") { model.checkForUpdates() }
                }
            } footer: {
                Text("softlock by oguzberkacar — a menu bar lock that keeps local agents running while blocking casual access to your Mac.")
            }

            Section {
                ForEach(model.changelog, id: \.version) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Version \(entry.version)  ·  \(entry.date)")
                            .font(.body.weight(.semibold))
                        ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                Text(change)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("What\u{2019}s New")
            }

            Section {
                LabeledContent("Reset all settings") {
                    Button("Reset…") { model.resetAllSettings() }
                }
                LabeledContent("Delete passcode, data and permissions") {
                    Button("Delete SoftLock…", role: .destructive) { model.deleteApp() }
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("Delete SoftLock clears your passcode, settings, face data and the macOS permission grants (Accessibility, Screen Recording, Camera), then quits — so a reinstall starts clean without stale permissions to remove by hand.")
            }
        }
        .formStyle(.grouped)
    }

    private var versionText: String {
        if let build = model.build, build != model.version {
            return "\(model.version) (\(build))"
        }
        return model.version
    }
}

// MARK: - AppKit bridges

/// Wraps the AppKit shortcut recorder for the form. Recording a new combo suspends the global
/// hot keys so the recorder can see every key, including the current lock shortcut.
private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: LockShortcut
    let recordOnAppear: Bool
    let onChange: (LockShortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView(shortcut: shortcut)
        view.onRecordingChange = { recording in
            if recording {
                HotKeyCenter.shared.suspend()
            } else {
                HotKeyCenter.shared.resume()
            }
        }
        view.onChange = { [onChange] changed in
            if !onChange(changed) {
                // Refused (combo already taken elsewhere): show the stored value again.
                view.update(shortcut)
            }
        }
        if recordOnAppear {
            DispatchQueue.main.async { view.beginRecording() }
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onChange = { [onChange, shortcut] changed in
            if !onChange(changed) {
                view.update(shortcut)
            }
        }
        if view.shortcut != shortcut {
            view.update(shortcut)
        }
    }
}
