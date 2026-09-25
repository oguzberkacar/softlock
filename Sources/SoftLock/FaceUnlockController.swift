//
//  FaceUnlockController.swift
//
//  Lock-screen face scanning. LockerController calls `begin` when the lock screen goes up and
//  `stop` when it comes down; on a confirmed match + liveness the `onUnlock` callback is invoked,
//  which takes the same path a successful Touch ID does. The password / PIN / recovery code
//  always stay available: this only ever adds a way in, never removes one.
//
//  Face unlock is weaker than Touch ID or the passcode. It uses a 2D camera; liveness checks
//  raise the bar against a printed photo but cannot rule out a determined attacker with a
//  video or mask. The Settings pane says so.
//

import AppKit
import AVFoundation
import Foundation
import SoftLockCore

@MainActor
final class FaceUnlockSettings {
    static let shared = FaceUnlockSettings()
    static let didChangeNotification = Notification.Name("SoftLockFaceUnlockSettingsDidChange")

    private let enabledKey = "faceUnlockEnabled"
    private let livenessKey = "faceUnlockLiveness"
    private let autoScanKey = "faceUnlockAutoScan"
    private let defaults = UserDefaults.standard

    /// Light (glance's own default) is deny-only: it blocks a face that looks like a photo or a
    /// screen, but never blocks an owner who sits perfectly still. Heavy also demands a blink or a
    /// head turn within the scan.
    var livenessMode: LivenessMode {
        get {
            guard let raw = defaults.string(forKey: livenessKey), let mode = LivenessMode(rawValue: raw) else {
                return .light
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: livenessKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Off by default: the lock screen waits for the camera button (or the Space key) instead of
    /// scanning the moment it goes up. Auto-scanning means walking past the Mac can unlock it
    /// again seconds after locking it, which defeats locking before leaving the desk.
    var autoScanOnLock: Bool {
        get { defaults.bool(forKey: autoScanKey) }
        set {
            defaults.set(newValue, forKey: autoScanKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Default off. Turning it on is only possible with an enrolled face and an installed model.
    var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set {
            defaults.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Everything face unlock needs, without prompting for anything.
    var isReadyForLockScreen: Bool {
        isEnabled
            && FaceUnlockStore.hasProfile
            && ArcFaceEmbedder.isModelAvailable
            && FaceCameraFeed.authorizationStatus == .authorized
    }
}

/// What the lock screen shows about face unlock. `kind` picks the accent dot; the text is always
/// drawn light on a dark pill.
enum FaceUnlockStatusKind: Sendable {
    case info
    case success
    case warning
    case error
}

/// State of the small self-view ring: scanning = white, recognized = green, not recognized = red.
enum FaceUnlockViewState: Sendable {
    case scanning
    case recognized
    case notRecognized
}

enum FaceUnlockEvent {
    case status(String, FaceUnlockStatusKind)
    /// The capture session that feeds recognition is running; the self-view attaches its preview
    /// to it (no second session).
    case cameraReady(AVCaptureSession)
    case state(FaceUnlockViewState)
    /// Face unlock is not running (paused, finished or stopped); the self-view goes away.
    case ended
}

@MainActor
final class FaceUnlockController {
    static let shared = FaceUnlockController()

    private static let scanDuration: TimeInterval = 10
    private static let retryDelay: Duration = .milliseconds(1500)
    /// Lets the green ring and tick on the self-view register before the lock screen goes away.
    private static let successBeat: Duration = .milliseconds(800)
    /// Consecutive face-less frames after which the liveness window and match streak restart.
    private static let faceGapResetFrames = 20

    private var throttle = FaceUnlockThrottle()
    private var task: Task<Void, Never>?
    /// True from `begin` until the scan cycle ends (success, timeout, pause or `stop`). The lock
    /// screen uses it to keep its camera button from starting a second scan on top of one.
    private(set) var isScanning = false
    private var generation = 0
    private let camera = FaceCameraFeed()

    private enum ScanOutcome {
        case unlocked
        /// No prompt-worthy face at all; not a miss.
        case noFaceSeen
        /// Face never in a judgeable pose; a prompt, not a miss.
        case noClearFrame
        /// Face matched, blink / head turn still missing; a prompt, not a miss.
        case needsLiveness
        /// A judgeable face did not match. Carries the last judged frame for the miss photo.
        case rejected(FaceCameraFrame?)
        case cancelled

        var isLivenessPrompt: Bool {
            if case .needsLiveness = self { return true }
            return false
        }
    }

    /// Starts scanning if face unlock is fully set up. Safe to call on every lock.
    /// - Parameters:
    ///   - onEvent: status text, camera-ready and self-view state updates for the lock screen.
    ///   - onMissFrame: nil unless failed-attempt photos are enabled; called at most once per miss
    ///     with the last judged frame (a face was present but not recognized).
    ///   - onUnlock: called once on success; returns false when the lock screen refuses (for example during a brute-force lockout).
    func begin(
        onEvent: @escaping (FaceUnlockEvent) -> Void,
        onMissFrame: ((FaceCameraFrame) -> Void)?,
        onUnlock: @escaping () -> Bool
    ) {
        stop()
        guard FaceUnlockSettings.shared.isReadyForLockScreen else { return }
        guard !throttle.isBlocked else {
            onEvent(.status("Face unlock is paused. Use your password.", .warning))
            return
        }
        generation &+= 1
        let current = generation
        isScanning = true
        task = Task { [weak self] in
            await self?.run(generation: current, onEvent: onEvent, onMissFrame: onMissFrame, onUnlock: onUnlock)
            guard let self, current == self.generation else { return }
            self.isScanning = false
            // `run` can also return before the camera ever started (unreadable profile, camera
            // failure). `.ended` is idempotent, and without it the lock screen would keep its
            // camera button disabled forever waiting for a scan that never began.
            onEvent(.ended)
        }
    }

    func stop() {
        isScanning = false
        generation &+= 1
        task?.cancel()
        task = nil
        camera.stop()
    }

    /// Any successful non-face unlock proves the owner is present, so the failure count restarts.
    func noteUnlockedByOtherMeans() {
        throttle.reset()
    }

    /// Forgets failures and any live scan; used when the face profile changes.
    func reset() {
        stop()
        throttle.reset()
    }

    // MARK: - Scan cycle

    private func run(
        generation current: Int,
        onEvent: @escaping (FaceUnlockEvent) -> Void,
        onMissFrame: ((FaceCameraFrame) -> Void)?,
        onUnlock: @escaping () -> Bool
    ) async {
        let profile: FaceProfile?
        do {
            profile = try FaceUnlockStore.load()
        } catch {
            AppFaceLog.write("face unlock: profile unreadable: \(error.localizedDescription)")
            return
        }
        guard let profile, profile.modelIdentifier == ArcFaceEmbedder.modelIdentifier,
              let template = profile.template else { return }

        let embedder: ArcFaceEmbedder
        do {
            embedder = try await Task.detached(priority: .userInitiated) { try ArcFaceEmbedder() }.value
        } catch {
            AppFaceLog.write("face unlock: model load failed: \(error.localizedDescription)")
            return
        }
        guard current == generation else { return }

        do {
            try await camera.start()
        } catch {
            AppFaceLog.write("face unlock: camera start failed: \(error.localizedDescription)")
            return
        }
        // A stop() during the start (the user unlocked another way) already stopped the session:
        // do not hand a dead session to the lock screen's preview.
        guard current == generation, !Task.isCancelled else {
            camera.stop()
            return
        }
        onEvent(.cameraReady(camera.session))
        defer {
            if current == generation {
                camera.stop()
                onEvent(.ended)
            }
        }

        var promptCycles = 0
        while !throttle.isBlocked, current == generation, !Task.isCancelled {
            onEvent(.state(.scanning))
            onEvent(.status("Looking for your face. Blink or turn your head slightly.", .info))
            let outcome = await scanOnce(generation: current, embedder: embedder, template: template, onEvent: onEvent, onUnlock: onUnlock)
            guard current == generation else { return }

            switch outcome {
            case .unlocked, .cancelled:
                return
            case .noFaceSeen:
                // Nobody in front of the camera is not an attack; do not count it.
                onEvent(.status("No face seen. Enter your password.", .info))
                return
            case .noClearFrame, .needsLiveness:
                // The owner may simply be holding still or at an angle. Prompt, never count a miss.
                promptCycles += 1
                if promptCycles >= FaceScanTimeoutOutcome.maximumPromptCycles {
                    onEvent(.status("Face unlock could not confirm it is you. Use your password.", .warning))
                    return
                }
                let prompt = outcome.isLivenessPrompt ? "Blink or turn slightly." : "Face the camera straight on."
                onEvent(.status(prompt, .info))
                try? await Task.sleep(for: .milliseconds(600))
            case .rejected(let frame):
                promptCycles = 0
                throttle.recordFailure()
                onEvent(.state(.notRecognized))
                // One photo per miss event, and only when a judged face was actually present.
                if let frame, let onMissFrame { onMissFrame(frame) }
                if throttle.isBlocked {
                    onEvent(.status("Face unlock paused after \(throttle.maxFailures) misses. Use your password.", .error))
                    return
                }
                onEvent(.status("Face not recognized. Trying again…", .error))
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    private func scanOnce(
        generation current: Int,
        embedder: ArcFaceEmbedder,
        template: FaceTemplate,
        onEvent: (FaceUnlockEvent) -> Void,
        onUnlock: () -> Bool
    ) async -> ScanOutcome {
        let policy = FaceMatchPolicy()
        var decider = FaceScanDecider()
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { FaceUnlockSettings.shared.livenessMode }

        let deadline = Date().addingTimeInterval(Self.scanDuration)
        var lastBox: CGRect?
        var lastFrameID: UInt64?
        var sawFace = false
        var judgedFrames = 0
        var lastJudgedFrame: FaceCameraFrame?
        var promptedLiveness = false

        while Date() < deadline, current == generation, !Task.isCancelled {
            guard let frame = camera.latestFrame(), frame.id != lastFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFrameID = frame.id
            let previous = lastBox

            let processed = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? FaceRecognitionPipeline.recognize(in: frame.image, embedder: embedder, preferNear: previous) else {
                    return nil
                }
                let crop = FaceCameraFeed.renderCrop(from: frame, imageRect: result.face.boundingBox)
                let liveFrame = LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: crop)
                return (result, liveFrame)
            }.value
            guard current == generation else { return .cancelled }

            guard let (result, liveFrame) = processed else {
                lastBox = nil
                _ = decider.observe(.noFace)
                if decider.noFaceStreak >= Self.faceGapResetFrames {
                    decider.reset()
                    liveness.reset()
                }
                continue
            }
            sawFace = true
            lastBox = result.face.normalizedBoundingBox

            let snapshot = liveness.observe(liveFrame)
            let verdict: FaceLivenessVerdict
            switch snapshot.decision {
            case .denied: verdict = .denied
            case .confirmed: verdict = .confirmed
            case .pending: verdict = .pending
            }

            // Frames that cannot be judged fairly are ignored (they neither match nor count as a
            // wrong face); the scan still times out to the password if no good frame ever matches.
            // Blink / head-turn liveness sends the face through big angles and blurry frames, and
            // treating those as "wrong face" tripped the streak limit for the real owner.
            if FaceScanFrameGate.isUnjudgeable(quality: result.face.quality, yaw: result.face.yaw, pitch: result.face.pitch) {
                continue
            }

            let score = policy.score(result.embedding, against: template)
            let matched = policy.isMatch(score)
            judgedFrames += 1
            lastJudgedFrame = frame
            let decision = decider.observe(.face(matched: matched, liveness: verdict))
            switch decision {
            case .pending:
                // The face is right; only the blink / turn is missing. Say so instead of
                // letting the scan silently run out and read as a wrong face.
                if decider.isAwaitingLiveness, !promptedLiveness {
                    promptedLiveness = true
                    onEvent(.status("Blink or turn slightly.", .info))
                }
                continue
            case .unlock:
                onEvent(.state(.recognized))
                onEvent(.status("Face recognized.", .success))
                try? await Task.sleep(for: Self.successBeat)
                guard current == generation, !Task.isCancelled else { return .cancelled }
                return onUnlock() ? .unlocked : .cancelled
            case .rejectedWrongFace, .rejectedSpoof:
                AppFaceLog.write("face reject: \(decision) score=\(score) matched=\(matched) liveness=\(verdict) snapshot=\(snapshot)")
                return .rejected(lastJudgedFrame)
            }
        }
        switch FaceScanTimeoutOutcome.classify(sawFace: sawFace, judgedFrames: judgedFrames, awaitingLiveness: decider.isAwaitingLiveness) {
        case .noFace: return .noFaceSeen
        case .noClearFrame: return .noClearFrame
        case .needsLiveness: return .needsLiveness
        case .notRecognized: return .rejected(lastJudgedFrame)
        }
    }
}

/// Tiny wrapper so the face files do not depend on main.swift's private logger.
nonisolated enum AppFaceLog {
    static func write(_ message: String) {
        let directory = FaceUnlockPaths.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("softlock.log")
        guard let data = "[\(Date())] \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
