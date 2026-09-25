//
//  FaceRecognitionTestWindow.swift
//
//  "Test Recognition": runs the same detect / align / embed / match pipeline the lock screen
//  uses against the enrolled face, live, and shows the similarity scores and a pass/fail, so
//  the result can be checked without locking the screen. It skips the liveness (blink / head
//  turn) gate, so a pass here means "the face matches", not "the lock screen would unlock".
//

import AppKit
import SoftLockCore

@MainActor
final class FaceRecognitionTestWindowController: NSObject, NSWindowDelegate {
    private static var current: FaceRecognitionTestWindowController?

    /// Opens (or focuses) the test window and starts a run.
    static func present() {
        if let current {
            current.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = FaceRecognitionTestWindowController()
        current = controller
        controller.show()
    }

    private static let scanDuration: TimeInterval = 8

    private let camera = FaceCameraFeed()
    private let window: NSWindow
    private let ring = FaceRingView()
    private let resultLabel = NSTextField(labelWithString: "")
    private let scoreLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let againButton = NSButton(title: "Test Again", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var closed = false

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Test Face Recognition"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        start()
    }

    private func buildContent() {
        let content = NSView()
        window.contentView = content

        resultLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        resultLabel.textColor = .labelColor
        resultLabel.alignment = .center

        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        scoreLabel.textColor = .labelColor
        scoreLabel.alignment = .center
        scoreLabel.maximumNumberOfLines = 2
        scoreLabel.preferredMaxLayoutWidth = 392

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        detailLabel.preferredMaxLayoutWidth = 392

        againButton.target = self
        againButton.action = #selector(againTapped)
        againButton.bezelStyle = .rounded
        againButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [againButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [ring, resultLabel, scoreLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 440),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            resultLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultLabel.heightAnchor.constraint(equalToConstant: 24),
            scoreLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scoreLabel.heightAnchor.constraint(equalToConstant: 36),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.heightAnchor.constraint(equalToConstant: 48),
        ])
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    // MARK: - Run

    private func start() {
        againButton.isHidden = true
        ring.resetProgress()
        ring.setTarget(nil)
        resultLabel.stringValue = "Looking for your face…"
        scoreLabel.stringValue = " "
        detailLabel.stringValue = "Look at the camera. This checks the face match only; the lock screen also asks for a blink or slight head turn."
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    private func finishRun(passed: Bool, headline: String, scores: String, detail: String) {
        camera.stop()
        resultLabel.stringValue = headline
        scoreLabel.stringValue = scores
        detailLabel.stringValue = detail
        againButton.isHidden = false
        if passed {
            ring.showComplete()
        } else {
            ring.showFailure()
            ring.flashError()
        }
    }

    private func run() async {
        guard ArcFaceEmbedder.isModelAvailable else {
            finishRun(passed: false, headline: "Model not installed", scores: " ", detail: "The face model (ArcFace.mlmodelc) is missing. Build the app with scripts/package-app.sh.")
            return
        }
        guard await FaceCameraFeed.requestAccess() else {
            finishRun(passed: false, headline: "Camera access is off", scores: " ", detail: "Allow SoftLock in System Settings > Privacy & Security > Camera, then test again.")
            return
        }
        let profile: FaceProfile?
        do { profile = try FaceUnlockStore.load() } catch {
            finishRun(passed: false, headline: "Face data unreadable", scores: " ", detail: error.localizedDescription)
            return
        }
        guard let profile, profile.modelIdentifier == ArcFaceEmbedder.modelIdentifier, let template = profile.template else {
            finishRun(passed: false, headline: "No face enrolled", scores: " ", detail: "Set up your face in Settings > Security first.")
            return
        }
        let embedder: ArcFaceEmbedder
        do {
            embedder = try await Task.detached(priority: .userInitiated) { try ArcFaceEmbedder() }.value
            try camera.start()
        } catch {
            finishRun(passed: false, headline: "Camera problem", scores: " ", detail: error.localizedDescription)
            return
        }
        if Task.isCancelled || closed { return }
        ring.attachPreview(session: camera.session)

        let policy = FaceMatchPolicy()
        var decider = FaceScanDecider()
        var lastBox: CGRect?
        var lastFrameID: UInt64?
        var sawFace = false
        var bestCentroid: Float = -1
        var bestSample: Float = -1
        var judged = 0
        let deadline = Date().addingTimeInterval(Self.scanDuration + FaceCameraFeed.warmUpDuration)

        while Date() < deadline {
            if Task.isCancelled || closed { return }
            guard let frame = camera.latestFrame(), frame.id != lastFrameID else {
                try? await Task.sleep(nanoseconds: 25_000_000)
                continue
            }
            lastFrameID = frame.id
            let previous = lastBox

            let result = await Task.detached(priority: .userInitiated) { () -> FaceRecognitionResult? in
                try? FaceRecognitionPipeline.recognize(in: frame.image, embedder: embedder, preferNear: previous)
            }.value
            if Task.isCancelled || closed { return }

            guard let result else {
                lastBox = nil
                _ = decider.observe(.noFace)
                resultLabel.stringValue = "Looking for your face…"
                continue
            }
            sawFace = true
            lastBox = result.face.normalizedBoundingBox

            if FaceScanFrameGate.isUnjudgeable(quality: result.face.quality, yaw: result.face.yaw, pitch: result.face.pitch) {
                resultLabel.stringValue = "Look straight at the camera"
                continue
            }

            let score = policy.score(result.embedding, against: template)
            judged += 1
            bestCentroid = max(bestCentroid, score.centroidSimilarity)
            bestSample = max(bestSample, score.maxSampleSimilarity)
            scoreLabel.stringValue = Self.scoreText(score, policy: policy)
            let matched = policy.isMatch(score)
            resultLabel.stringValue = matched ? "Matching…" : "Not matching yet"

            switch decider.observe(.face(matched: matched, liveness: .confirmed)) {
            case .pending:
                continue
            case .unlock:
                finishRun(passed: true, headline: "Recognized", scores: Self.scoreText(score, policy: policy),
                          detail: "Your face matches. Threshold \(Self.format(policy.threshold)); both scores must reach it.")
                return
            case .rejectedWrongFace, .rejectedSpoof:
                finishRun(passed: false, headline: "Not recognized",
                          scores: "Best  template \(Self.format(bestCentroid))  ·  sample \(Self.format(bestSample))  ·  needs \(Self.format(policy.threshold))",
                          detail: "Try more even light and face the camera. If this keeps failing, set up your face again.")
                return
            }
        }

        if !sawFace {
            finishRun(passed: false, headline: "No face found", scores: " ", detail: "Move into view of the camera with good light, then test again.")
        } else if judged == 0 {
            finishRun(passed: false, headline: "Could not get a clear frame", scores: " ", detail: "Face the camera straight on, hold still and improve the lighting.")
        } else {
            finishRun(passed: false, headline: "Not recognized",
                      scores: "Best  template \(Self.format(bestCentroid))  ·  sample \(Self.format(bestSample))  ·  needs \(Self.format(policy.threshold))",
                      detail: "It needs \(FaceScanDecider.defaultRequiredMatches) matching frames in a row. Hold still, face the camera and try again.")
        }
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private static func scoreText(_ score: FaceMatchScore, policy: FaceMatchPolicy) -> String {
        "Template \(format(score.centroidSimilarity))  ·  best sample \(format(score.maxSampleSimilarity))  ·  needs \(format(policy.threshold))"
    }

    // MARK: - Actions

    @objc private func againTapped() {
        start()
    }

    @objc private func closeTapped() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        task?.cancel()
        camera.stop()
        if Self.current === self { Self.current = nil }
    }
}
