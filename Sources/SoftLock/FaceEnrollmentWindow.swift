//
//  FaceEnrollmentWindow.swift
//
//  Guided face capture in the style of jonnyoo/glance's onboarding (MIT, see
//  THIRD_PARTY_NOTICES.md): a circular mirrored camera preview inside a tick ring that fills
//  sector by sector as the head is turned toward each of eight directions (plus a straight-on
//  capture). Every frame gets explicit feedback: what is wrong, which way to turn, when a frame
//  was captured, and why a frame was rejected. Only embeddings are kept (encrypted, see
//  FaceUnlockStore); camera frames live in memory just long enough to be embedded.
//
//  Layout is pure Auto Layout: one vertical stack pinned to the content view, a fixed-size ring,
//  fixed-height text rows so the window never resizes or drifts while the text changes.
//  Pose windows, capture timing and consistency checks live in SoftLockCore and are unit tested.
//

@preconcurrency import AVFoundation
import AppKit
import SoftLockCore

/// Small colored dot whose color follows the feedback tone and the current appearance.
@MainActor
final class FaceStatusDot: NSView {
    var tone: EnrollmentFeedback.Tone = .neutral {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: 9) }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4.5
        let color: NSColor
        switch tone {
        case .neutral: color = .secondaryLabelColor
        case .good: color = .systemGreen
        case .warning: color = .systemOrange
        case .error: color = .systemRed
        }
        layer?.backgroundColor = color.cgColor
    }
}

@MainActor
final class FaceEnrollmentWindowController: NSObject, NSWindowDelegate {
    private enum Phase { case running, saved, failed }

    private nonisolated static let qualityFloor: Float = 0.25
    private nonisolated static let capturedHold: TimeInterval = 0.7

    private let camera = FaceCameraFeed()
    private let window: NSWindow
    private let ring = FaceRingView()
    private let instructionLabel = NSTextField(labelWithString: "")
    private let feedbackDot = FaceStatusDot()
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Open Camera Settings…", target: nil, action: nil)
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let testButton = NSButton(title: "Test Recognition", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private var captureTask: Task<Void, Never>?
    private var phase = Phase.running
    private var finished = false
    private var feedbackHoldUntil = Date.distantPast
    private let onFinish: (Bool) -> Void

    init(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Set Up Face Unlock"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        startCapture()
    }

    // MARK: - Layout

    private func buildContent() {
        let content = NSView()
        window.contentView = content

        instructionLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        instructionLabel.textColor = .labelColor
        instructionLabel.alignment = .center
        instructionLabel.lineBreakMode = .byTruncatingTail
        instructionLabel.stringValue = "Starting camera…"

        feedbackLabel.font = .systemFont(ofSize: 13)
        feedbackLabel.textColor = .labelColor
        feedbackLabel.alignment = .center
        feedbackLabel.maximumNumberOfLines = 2
        feedbackLabel.preferredMaxLayoutWidth = 360
        feedbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        feedbackLabel.stringValue = EnrollmentFeedback.starting.message

        progressLabel.font = .systemFont(ofSize: 12)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .center

        for (button, action) in [
            (cancelButton, #selector(cancelTapped)),
            (settingsButton, #selector(openCameraSettings)),
            (retryButton, #selector(retryTapped)),
            (testButton, #selector(testTapped)),
            (doneButton, #selector(doneTapped)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        cancelButton.keyEquivalent = "\u{1b}"
        doneButton.keyEquivalent = "\r"
        for button in [settingsButton, retryButton, testButton, doneButton] { button.isHidden = true }

        let feedbackRow = NSStackView()
        feedbackRow.setViews([feedbackDot, feedbackLabel], in: .center)
        feedbackRow.orientation = .horizontal
        feedbackRow.alignment = .centerY
        feedbackRow.spacing = 8
        feedbackRow.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [settingsButton, retryButton, testButton, cancelButton, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [ring, instructionLabel, feedbackRow, progressLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(6, after: feedbackRow)
        stack.setCustomSpacing(16, after: progressLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 440),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            instructionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructionLabel.heightAnchor.constraint(equalToConstant: 24),
            feedbackRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedbackRow.heightAnchor.constraint(equalToConstant: 36),
            progressLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    // MARK: - UI state

    private func setInstruction(_ text: String) {
        instructionLabel.stringValue = text
    }

    private func showFeedback(_ feedback: EnrollmentFeedback, force: Bool = false) {
        if !force, Date() < feedbackHoldUntil, feedback != .captured {
            if case .rejected = feedback {} else { return }
        }
        if feedback == .captured { feedbackHoldUntil = Date().addingTimeInterval(Self.capturedHold) }
        if case .rejected = feedback { feedbackHoldUntil = Date().addingTimeInterval(Self.capturedHold) }
        feedbackLabel.stringValue = feedback.message
        feedbackDot.tone = feedback.tone
    }

    private func showProgress(_ progress: EnrollmentProgress) {
        let total = EnrollmentPose.allCases.count
        if progress.isComplete {
            progressLabel.stringValue = "All \(total) directions captured"
        } else {
            let number = progress.poseIndex + 1
            progressLabel.stringValue = "Direction \(number) of \(total)  ·  frame \(progress.capturedInCurrent + 1) of \(progress.samplesPerPose)"
        }
    }

    private func setButtons(cancel: Bool, cancelTitle: String = "Cancel", settings: Bool = false, retry: Bool = false, test: Bool = false, done: Bool = false) {
        cancelButton.isHidden = !cancel
        cancelButton.title = cancelTitle
        settingsButton.isHidden = !settings
        retryButton.isHidden = !retry
        testButton.isHidden = !test
        doneButton.isHidden = !done
    }

    // MARK: - Capture flow

    private func startCapture() {
        phase = .running
        setButtons(cancel: true)
        ring.resetProgress()
        ring.setTarget(nil)
        setInstruction("Starting camera…")
        showFeedback(.starting, force: true)
        progressLabel.stringValue = ""
        captureTask?.cancel()
        captureTask = Task { [weak self] in await self?.begin() }
    }

    private func begin() async {
        guard ArcFaceEmbedder.isModelAvailable else {
            fail("The face model is not installed, so face unlock cannot be set up. Build the app with scripts/package-app.sh.", showSettings: false, canRetry: false)
            return
        }
        guard await FaceCameraFeed.requestAccess() else {
            fail("Camera access is off for SoftLock. Allow it in System Settings > Privacy & Security > Camera, then try again.", showSettings: true, canRetry: true)
            return
        }
        let embedder: ArcFaceEmbedder
        do {
            embedder = try await Task.detached(priority: .userInitiated) { try ArcFaceEmbedder() }.value
            try await camera.start()
        } catch {
            fail(error.localizedDescription, showSettings: false, canRetry: true)
            return
        }
        if Task.isCancelled || finished { return }
        ring.attachPreview(session: camera.session)

        var progress = EnrollmentProgress()
        var gate = EnrollmentCaptureGate()
        var samples: [FaceSampleRecord] = []
        var poseStartedAt = Date()
        var previousBox: FaceBoxSample?
        var lastFrameID: UInt64?

        let liveness = LivenessAnalyzer()
        // Enrollment only refuses frames with a spoof tell; it never demands a blink.
        liveness.modeProvider = { .light }

        ring.setTarget(progress.currentPose)
        setInstruction(progress.currentPose?.instruction ?? "")
        showProgress(progress)

        while !progress.isComplete {
            if Task.isCancelled || finished { return }
            guard let frame = camera.latestFrame() else {
                showFeedback(.starting)
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }
            guard frame.id != lastFrameID else {
                try? await Task.sleep(nanoseconds: 25_000_000)
                continue
            }
            lastFrameID = frame.id
            guard let pose = progress.currentPose else { break }

            let analysis = await Task.detached(priority: .userInitiated) { () -> Analysis in
                Self.analyze(frame, embedder: embedder)
            }.value
            if Task.isCancelled || finished { return }

            let measured: Measured
            switch analysis {
            case .noFace:
                reset(&gate, &previousBox, feedback: .noFace)
                continue
            case .multiple:
                reset(&gate, &previousBox, feedback: .multipleFaces)
                continue
            case .placement(let placement):
                let feedback: EnrollmentFeedback
                switch placement {
                case .tooFar: feedback = .tooFar
                case .tooClose: feedback = .tooClose
                default: feedback = .offCenter
                }
                reset(&gate, &previousBox, feedback: feedback)
                continue
            case .unreadable:
                reset(&gate, &previousBox, feedback: .poseUnreadable)
                continue
            case .measured(let value):
                measured = value
            }

            let face = measured.face
            guard let yaw = face.yaw, let pitch = face.pitch else {
                reset(&gate, &previousBox, feedback: .poseUnreadable)
                continue
            }
            ring.setHeadTurn(EnrollmentPoseEvaluator.headTurn(yaw: yaw, pitch: pitch, pose: pose))

            let snapshot = liveness.observe(measured.liveFrame)
            if case .denied(let cue) = snapshot.decision {
                let reason: EnrollmentRejection
                switch cue {
                case .glossGlare: reason = .screenGlare
                case .deviceDetected: reason = .deviceInView
                default: reason = .flatFace
                }
                liveness.reset()
                gate.reset()
                previousBox = measured.box
                showFeedback(.rejected(reason))
                ring.flashError()
                continue
            }

            let widened = Date().timeIntervalSince(poseStartedAt) > EnrollmentPoseBands.stallTimeout
            let assessment = EnrollmentPoseEvaluator.assess(yaw: yaw, pitch: pitch, pose: pose, widened: widened)
            let steady = previousBox.map { measured.box.isSteady(since: $0) } ?? false
            previousBox = measured.box

            guard assessment == .inWindow else {
                gate.reset()
                showFeedback(.forPose(assessment, pose: pose))
                continue
            }
            if let quality = face.quality, quality < Self.qualityFloor {
                gate.reset()
                showFeedback(.lowQuality)
                continue
            }
            switch measured.imageQuality {
            case .tooDark: gate.reset(); showFeedback(.tooDark); continue
            case .tooBright: gate.reset(); showFeedback(.tooBright); continue
            case .blurry: gate.reset(); showFeedback(.blurry); continue
            case .ok: break
            }
            guard steady else {
                gate.reset()
                showFeedback(.holdStill)
                continue
            }

            let now = Date().timeIntervalSinceReferenceDate
            guard gate.observe(accepted: true, now: now) else {
                showFeedback(.holding)
                continue
            }

            samples.append(FaceSampleRecord(embedding: measured.result.embedding, pose: pose.id))
            let event = progress.recordSample()
            showFeedback(.captured)
            if case .poseCompleted(_, let allDone) = event {
                ring.setCaptured(progress.completedPoses)
                ring.pulseCapture(sectorFilled: true)
                gate.reset()
                poseStartedAt = Date()
                liveness.reset()
                if !allDone {
                    ring.setTarget(progress.currentPose)
                    setInstruction(progress.currentPose?.instruction ?? "")
                }
            } else {
                ring.pulseCapture(sectorFilled: false)
            }
            showProgress(progress)
        }

        finish(samples: samples)
    }

    private func reset(_ gate: inout EnrollmentCaptureGate, _ previousBox: inout FaceBoxSample?, feedback: EnrollmentFeedback) {
        gate.reset()
        previousBox = nil
        ring.setHeadTurn(nil)
        showFeedback(feedback)
    }

    // MARK: - Analysis (off the main actor)

    private nonisolated struct Measured: @unchecked Sendable {
        let face: DetectedFace
        let result: FaceRecognitionResult
        let liveFrame: LivenessFrame
        let box: FaceBoxSample
        let imageQuality: FaceImageQuality
    }

    private nonisolated enum Analysis: @unchecked Sendable {
        case noFace
        case multiple
        case placement(FaceFramePlacement)
        case unreadable
        case measured(Measured)
    }

    private nonisolated static func analyze(_ frame: FaceCameraFrame, embedder: ArcFaceEmbedder) -> Analysis {
        guard let faces = try? FaceDetector.detectFaces(in: frame.image),
              let face = FaceRecognitionPipeline.largestFace(in: faces) else { return .noFace }
        let bystanders = faces.filter {
            $0.normalizedBoundingBox != face.normalizedBoundingBox
                && $0.normalizedBoundingBox.width >= FaceRecognitionPipeline.minimumProminentFaceWidth
        }
        if !bystanders.isEmpty { return .multiple }

        let normalized = face.normalizedBoundingBox
        let box = FaceBoxSample(midX: normalized.midX, midY: normalized.midY, width: normalized.width)
        let placement = FaceFramePlacement.assess(box)
        if placement != .ok { return .placement(placement) }

        guard let result = try? FaceRecognitionPipeline.recognize(face, in: frame.image, embedder: embedder) else {
            return .unreadable
        }
        let crop = FaceCameraFeed.renderCrop(from: frame, imageRect: face.boundingBox)
        let liveFrame = LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: crop)

        var imageQuality = FaceImageQuality.ok
        if let luma = lumaBytes(of: result.alignedImage) {
            imageQuality = FaceImageQuality.assess(luma: luma.bytes, width: luma.width, height: luma.height)
        }
        return .measured(Measured(face: face, result: result, liveFrame: liveFrame, box: box, imageQuality: imageQuality))
    }

    /// Grayscale bytes of the central part of the aligned 112x112 face (skips the warp's black corners).
    private nonisolated static func lumaBytes(of aligned: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let inset = 16
        let side = aligned.width - inset * 2
        guard side > 8, let cropped = aligned.cropping(to: CGRect(x: inset, y: inset, width: side, height: side)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? (bytes, side, side) : nil
    }

    // MARK: - Finish

    private func finish(samples: [FaceSampleRecord]) {
        let centerID = EnrollmentPose.center.id
        let center = samples.filter { $0.pose == centerID }
        let others = samples.filter { $0.pose != centerID }

        let kept: [FaceSampleRecord]
        switch FaceEnrollmentConsistency.evaluate(center: center.map(\.embedding), others: others.map(\.embedding)) {
        case .ok(let mask):
            kept = center + zip(others, mask).filter { $0.1 }.map { $0.0 }
        case .centerInconsistent:
            fail("The straight-on frames did not match each other. Sit in even light, keep only your face in view, and try again.", showSettings: false, canRetry: true)
            return
        case .tooManyOutliers:
            fail("Some turned frames did not look like the same person as the straight-on ones (lighting or another face in view). Try again in even light.", showSettings: false, canRetry: true)
            return
        }

        guard FaceTemplate(samples: kept.map(\.embedding)) != nil else {
            fail("Could not build a face signature. Please try again.", showSettings: false, canRetry: true)
            return
        }

        let profile = FaceProfile(modelIdentifier: ArcFaceEmbedder.modelIdentifier, createdAt: Date(), samples: kept)
        do {
            try FaceUnlockStore.save(profile)
        } catch {
            fail("Could not save the face data: \(error.localizedDescription)", showSettings: false, canRetry: true)
            return
        }
        FaceUnlockController.shared.reset()

        phase = .saved
        camera.stop()
        ring.showComplete()
        setInstruction("Face saved")
        showFeedback(EnrollmentFeedback.captured, force: true)
        feedbackLabel.stringValue = "Only an encrypted numeric signature is stored on this Mac. Run a test to check it recognizes you."
        progressLabel.stringValue = "All \(EnrollmentPose.allCases.count) directions captured"
        setButtons(cancel: false, test: true, done: true)
    }

    private func fail(_ message: String, showSettings: Bool, canRetry: Bool) {
        phase = .failed
        captureTask?.cancel()
        camera.stop()
        ring.showFailure()
        setInstruction("Face setup didn't finish")
        feedbackLabel.stringValue = message
        feedbackDot.tone = .error
        progressLabel.stringValue = ""
        setButtons(cancel: true, cancelTitle: "Close", settings: showSettings, retry: canRetry)
    }

    private func complete(success: Bool) {
        guard !finished else { return }
        finished = true
        captureTask?.cancel()
        camera.stop()
        window.close()
        onFinish(success)
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        complete(success: phase == .saved)
    }

    @objc private func doneTapped() {
        complete(success: true)
    }

    @objc private func retryTapped() {
        guard phase == .failed else { return }
        startCapture()
    }

    @objc private func testTapped() {
        complete(success: true)
        FaceRecognitionTestWindowController.present()
    }

    @objc private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        captureTask?.cancel()
        camera.stop()
        onFinish(phase == .saved)
    }
}
