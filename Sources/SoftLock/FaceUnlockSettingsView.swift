//
//  FaceUnlockSettingsView.swift
//
//  The "Unlock with Face" block for Settings > Security. Self-contained Auto Layout view so the
//  host only has to drop it into a settings group.
//

import AppKit
import SoftLockCore

@MainActor
final class FaceUnlockSettingsView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Unlock with Face")
    private let toggle = NSSwitch()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let enrollButton = NSButton(title: "Set Up Face…", target: nil, action: nil)
    private let testButton = NSButton(title: "Test Recognition…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Face Data", target: nil, action: nil)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let autoScanSwitch = NSSwitch()
    private let autoScanLabel = NSTextField(labelWithString: "Scan automatically when locked")
    private let autoScanHint = NSTextField(wrappingLabelWithString: "")
    private let livenessPopUp = NSPopUpButton()
    private let livenessLabel = NSTextField(labelWithString: "Liveness checks")
    private let livenessHint = NSTextField(wrappingLabelWithString: "")
    private var enrollment: FaceEnrollmentWindowController?

    private static let contentWidth: CGFloat = 488

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        toggle.target = self
        toggle.action = #selector(toggleChanged)

        let header = NSStackView(views: [titleLabel, toggle])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = Self.contentWidth

        enrollButton.target = self
        enrollButton.action = #selector(enrollTapped)
        enrollButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.bezelStyle = .rounded
        autoScanLabel.font = .systemFont(ofSize: 13)
        autoScanLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        autoScanSwitch.target = self
        autoScanSwitch.action = #selector(autoScanChanged)
        let autoScanRow = NSStackView(views: [autoScanLabel, autoScanSwitch])
        autoScanRow.orientation = .horizontal
        autoScanRow.alignment = .centerY
        autoScanHint.font = .systemFont(ofSize: 11.5)
        autoScanHint.textColor = .secondaryLabelColor
        autoScanHint.preferredMaxLayoutWidth = Self.contentWidth

        livenessLabel.font = .systemFont(ofSize: 13)
        livenessLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        livenessPopUp.target = self
        livenessPopUp.action = #selector(livenessChanged)
        for mode in LivenessMode.allCases {
            livenessPopUp.addItem(withTitle: mode.title)
            livenessPopUp.lastItem?.representedObject = mode.rawValue
        }
        let livenessRow = NSStackView(views: [livenessLabel, livenessPopUp])
        livenessRow.orientation = .horizontal
        livenessRow.alignment = .centerY
        livenessHint.font = .systemFont(ofSize: 11.5)
        livenessHint.textColor = .secondaryLabelColor
        livenessHint.preferredMaxLayoutWidth = Self.contentWidth

        let buttons = NSStackView(views: [enrollButton, testButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        warningLabel.font = .systemFont(ofSize: 11.5)
        warningLabel.textColor = .systemOrange
        warningLabel.preferredMaxLayoutWidth = Self.contentWidth
        warningLabel.stringValue = "Less secure than Touch ID or your passcode. Face unlock uses the regular 2D camera, and liveness checks cannot rule out a video or a good mask of you. Use it for convenience, not for protecting sensitive data. Your passcode always works, and after \(FaceUnlockThrottle.defaultMaxFailures) missed scans face unlock pauses until you unlock another way. Only encrypted face signatures are stored, on this Mac; camera frames are never saved."

        let stack = NSStackView(views: [header, statusLabel, buttons, autoScanRow, autoScanHint, livenessRow, livenessHint, warningLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            autoScanRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            autoScanHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            livenessRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            livenessHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            warningLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - State

    private func refresh() {
        let modelAvailable = ArcFaceEmbedder.isModelAvailable
        let enrolled = FaceUnlockStore.hasProfile
        let settings = FaceUnlockSettings.shared

        if enrolled == false, settings.isEnabled { settings.isEnabled = false }
        refreshLivenessHint()
        refreshAutoScan()
        toggle.state = settings.isEnabled ? .on : .off
        toggle.isEnabled = modelAvailable && enrolled
        enrollButton.title = enrolled ? "Re-enroll Face…" : "Set Up Face…"
        enrollButton.isEnabled = modelAvailable
        testButton.isEnabled = enrolled && modelAvailable
        deleteButton.isEnabled = enrolled

        if !modelAvailable {
            statusLabel.stringValue = "Unavailable: the face model (ArcFace.mlmodelc) is not installed. Build with scripts/package-app.sh, or copy it to ~/Library/Application Support/\(FaceUnlockPaths.appIdentifier)/."
            statusLabel.textColor = .systemRed
        } else if !enrolled {
            statusLabel.stringValue = "No face enrolled. Set up your face first, then turn this on. Off by default."
            statusLabel.textColor = .secondaryLabelColor
        } else if FaceCameraFeed.authorizationStatus == .denied || FaceCameraFeed.authorizationStatus == .restricted {
            statusLabel.stringValue = "Face enrolled, but camera access is off for SoftLock (System Settings > Privacy & Security > Camera)."
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = settings.isEnabled
                ? (settings.autoScanOnLock
                    ? "On. The lock screen scans for your face as soon as it appears."
                    : "On. On the lock screen, press Space or tap the camera button to scan.")
                : "Face enrolled. Turn on to use it on the lock screen."
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Actions

    private func refreshAutoScan() {
        let settings = FaceUnlockSettings.shared
        autoScanSwitch.state = settings.autoScanOnLock ? .on : .off
        autoScanSwitch.isEnabled = settings.isEnabled
        autoScanLabel.textColor = settings.isEnabled ? .labelColor : .disabledControlTextColor
        autoScanHint.stringValue = settings.autoScanOnLock
            ? "The camera starts looking the moment the lock screen appears — walking past the Mac can unlock it right after you lock it."
            : "The lock screen waits for you: press Space or tap the camera button to scan. Recommended if you lock before leaving the desk."
        autoScanHint.textColor = settings.autoScanOnLock ? .systemOrange : .secondaryLabelColor
    }

    @objc private func autoScanChanged() {
        FaceUnlockSettings.shared.autoScanOnLock = autoScanSwitch.state == .on
        refreshAutoScan()
    }

    @objc private func livenessChanged() {
        guard let raw = livenessPopUp.selectedItem?.representedObject as? String,
              let mode = LivenessMode(rawValue: raw) else { return }
        FaceUnlockSettings.shared.livenessMode = mode
        refreshLivenessHint()
    }

    private func refreshLivenessHint() {
        let mode = FaceUnlockSettings.shared.livenessMode
        livenessPopUp.selectItem(at: LivenessMode.allCases.firstIndex(of: mode) ?? 0)
        switch mode {
        case .off:
            livenessHint.stringValue = "No liveness check: a printed photo or a phone showing your face can unlock. Least secure."
            livenessHint.textColor = .systemOrange
        case .light:
            livenessHint.stringValue = "Blocks faces that look like a photo or a screen. Works while you sit still. Recommended."
            livenessHint.textColor = .secondaryLabelColor
        case .heavy:
            livenessHint.stringValue = "Also needs a blink or a slight head turn during the scan. Holding still falls back to your passcode."
            livenessHint.textColor = .secondaryLabelColor
        }
    }

    @objc private func toggleChanged() {
        let wantsOn = toggle.state == .on
        guard wantsOn else {
            FaceUnlockSettings.shared.isEnabled = false
            FaceUnlockController.shared.reset()
            refresh()
            return
        }
        Task { [weak self] in
            // Ask for camera permission now, in Settings, where the system prompt is visible.
            let granted = await FaceCameraFeed.requestAccess()
            guard let self else { return }
            FaceUnlockSettings.shared.isEnabled = granted
            self.refresh()
        }
    }

    @objc private func enrollTapped() {
        guard enrollment == nil else { return }
        let controller = FaceEnrollmentWindowController { [weak self] _ in
            self?.enrollment = nil
            self?.refresh()
        }
        enrollment = controller
        controller.show()
    }

    @objc private func testTapped() {
        FaceRecognitionTestWindowController.present()
    }

    @objc private func deleteTapped() {
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
}
