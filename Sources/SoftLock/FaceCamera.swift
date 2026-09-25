//
//  FaceCamera.swift
//
//  Camera feed for face unlock and enrollment. Frames are kept in memory only (the newest one)
//  and are never written to disk. Adapted from jonnyoo/glance's CameraManager (MIT) — see
//  THIRD_PARTY_NOTICES.md.
//

@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// `source` is a lazy `CIImage` at native resolution, only rendered by `renderCrop` for the
/// glare cue; `image` is the downscaled frame Vision works on.
struct FaceCameraFrame: @unchecked Sendable {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

enum FaceCameraError: LocalizedError {
    case notAuthorized
    case noDevice
    case cannotConfigure

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access is not granted. Enable it in System Settings > Privacy & Security > Camera."
        case .noDevice: return "No camera was found."
        case .cannotConfigure: return "The camera could not be configured."
        }
    }
}

final class FaceCameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "\(FaceUnlockPaths.appIdentifier).face-camera")
    private let lock = NSLock()
    private var latest: FaceCameraFrame?
    private var nextID: UInt64 = 0
    private var configured = false
    /// Frames delivered before this instant are dark / mid-exposure and are never handed out:
    /// a dim first frame embeds badly and used to count as a "wrong face" on the lock screen.
    private var warmUpDeadline = Date.distantFuture
    static let warmUpDuration: TimeInterval = 1.0
    private let ciContext = CIContext()
    private let maxLongEdge: CGFloat = 640

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Prompts only when undetermined. Call from Settings, never from the lock screen (the
    /// system prompt would appear behind the lock windows).
    static func requestAccess() async -> Bool {
        switch authorizationStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Starts capture without prompting, and returns only once the session is actually running.
    /// Throws if camera access is not already granted.
    ///
    /// Waiting matters: callers attach an `AVCaptureVideoPreviewLayer` as soon as this returns,
    /// and attaching one mutates the session's connections. Doing that while `startRunning()` is
    /// still walking those connections on the camera queue throws a collection-mutation
    /// exception from inside AVFoundation, which aborts the process. Every session mutation
    /// therefore happens on `queue`, and nothing else touches the session until it is done.
    func start() async throws {
        guard Self.authorizationStatus == .authorized else { throw FaceCameraError.notAuthorized }
        resetFrameState()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configureIfNeeded()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    /// Blocks until the session has stopped, for the same reason `start` waits: the caller tears
    /// the preview down straight afterwards.
    func stop() {
        queue.sync { [session] in
            if session.isRunning { session.stopRunning() }
        }
        lock.lock()
        latest = nil
        lock.unlock()
    }

    /// Drops the last frame and restarts the warm-up window. Not `async`-callable inline because
    /// `NSLock` is unavailable from async contexts, hence the separate non-async method.
    private func resetFrameState() {
        lock.lock()
        latest = nil
        warmUpDeadline = Date().addingTimeInterval(Self.warmUpDuration)
        lock.unlock()
    }

    /// The newest frame, or nil while the camera is still warming up (auto-exposure settling).
    func latestFrame() -> FaceCameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard Date() >= warmUpDeadline else { return nil }
        return latest
    }

    var isWarmingUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() < warmUpDeadline
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            throw FaceCameraError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard session.canAddInput(input) else { throw FaceCameraError.cannotConfigure }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw FaceCameraError.cannotConfigure }
        session.addOutput(output)
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = source.extent
        var scaled = source
        let longEdge = max(scaled.extent.width, scaled.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            scaled = scaled.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }

        lock.lock()
        nextID &+= 1
        latest = FaceCameraFrame(id: nextID, image: cgImage, source: source, sourceSize: sourceExtent.size)
        lock.unlock()
    }

    /// Native-resolution crop around `imageRect` (top-left/y-down, in `frame.image` pixels), for
    /// the gloss/glare cue, which needs detail the downscaled frame throws away.
    static func renderCrop(from frame: FaceCameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)
        nativeRect = nativeRect.intersection(CGRect(origin: .zero, size: frame.sourceSize))
        guard !nativeRect.isEmpty else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }

    private static let cropRenderContext = CIContext()

    /// JPEG of the full-resolution frame, for the failed-attempt photo. Produced on demand from
    /// a frame already in memory; nothing is written by the feed itself.
    nonisolated static func jpegData(from frame: FaceCameraFrame, quality: CGFloat = 0.85) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return cropRenderContext.jpegRepresentation(
            of: frame.source,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
