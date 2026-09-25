//
//  FaceRecognition.swift
//
//  Face detection, 5-point alignment to the ArcFace 112x112 template, and the Core ML embedder.
//  Adapted from jonnyoo/glance (MIT) — see THIRD_PARTY_NOTICES.md.
//

import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import SoftLockCore
@preconcurrency import Vision

// MARK: - Detection

struct DetectedFace: @unchecked Sendable {
    /// Pixel-space bounding box, top-left origin — ready to crop with.
    let boundingBox: CGRect
    /// Vision's original normalized box — kept as-is since it's the exact format `layerRectConverted(fromMetadataOutputRect:)` expects.
    let normalizedBoundingBox: CGRect
    /// 0...1 confidence from Vision that this is a face, roughly indicating
    /// image quality/pose suitability for recognition. `nil` if the quality
    /// request didn't produce a result for this face.
    let quality: Float?
    /// Head rotation in radians, when Vision could estimate it. Yaw > 0 is the person turning to their left,
    /// pitch < 0 is looking up. Both drive the guided enrollment; roll is exposed but unused.
    let yaw: Float?
    let roll: Float?
    let pitch: Float?
    /// Facial landmarks (eyes, nose, mouth, etc.), when available. Feeds
    /// `FaceAligner` for canonical 112x112 alignment ahead of ArcFace.
    nonisolated let landmarks: VNFaceLandmarks2D?
    /// Needed by `landmarks.pointsInImage(_:)` to convert normalized landmark points into `boundingBox`'s pixel space.
    let imageSize: CGSize
}

/// Pure, synchronous, CPU-bound work — `nonisolated` so it can run on a
/// background task despite the project's default main-actor isolation.
nonisolated enum FaceDetector {
    /// Runs face-rectangle, capture-quality, and landmarks detection on a single frame.
    static func detectFaces(in image: CGImage) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([rectanglesRequest])
        let faceObservations = rectanglesRequest.results ?? []
        guard !faceObservations.isEmpty else { return [] }

        // Chained to the rectangles results (via `inputFaceObservations`) rather than run independently, so results
        // correspond 1:1 in order — avoids the fragility of matching back via boundingBox float equality.
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        qualityRequest.inputFaceObservations = faceObservations
        landmarksRequest.inputFaceObservations = faceObservations
        try handler.perform([qualityRequest, landmarksRequest])

        let qualityResults = qualityRequest.results ?? []
        let landmarkResults = landmarksRequest.results ?? []
        let imageSize = CGSize(width: image.width, height: image.height)

        return faceObservations.enumerated().map { index, observation in
            let pixelRect = convertToImageSpace(observation.boundingBox, imageSize: imageSize)
            return DetectedFace(
                boundingBox: pixelRect,
                normalizedBoundingBox: observation.boundingBox,
                quality: qualityResults.indices.contains(index) ? qualityResults[index].faceCaptureQuality : nil,
                yaw: observation.yaw?.floatValue,
                roll: observation.roll?.floatValue,
                pitch: observation.pitch?.floatValue,
                landmarks: landmarkResults.indices.contains(index) ? landmarkResults[index].landmarks : nil,
                imageSize: imageSize
            )
        }
    }

    /// Vision's normalized rect has origin at bottom-left; `CGImage.cropping`
    /// expects pixel coordinates with origin at top-left. This flips the Y axis.
    static func convertToImageSpace(_ normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let x = normalizedRect.origin.x * imageSize.width
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let y = (1 - normalizedRect.origin.y) * imageSize.height - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Crops `face` out of `image`, padding slightly around the detected box
    /// so the embedder sees a bit of context beyond just eyes/nose/mouth.
    static func crop(_ face: DetectedFace, from image: CGImage, paddingFraction: CGFloat = 0.2) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let padX = face.boundingBox.width * paddingFraction
        let padY = face.boundingBox.height * paddingFraction
        let padded = face.boundingBox.insetBy(dx: -padX, dy: -padY).intersection(imageBounds)
        guard !padded.isEmpty else { return nil }
        return image.cropping(to: padded)
    }
}

// MARK: - Alignment

struct AlignedFace: @unchecked Sendable {
    let image: CGImage   // 112x112, canonically aligned
    let tier: AlignmentTier
}

enum AlignmentTier: String {
    case fivePoint = "5-point"
    case twoPoint = "2-point (eyes only)"
    case paddedCrop = "padded crop (no alignment)"
}

nonisolated enum FaceAligner {
    static let outputSize = 112

    /// Standard ArcFace 112x112 template: left eye, right eye, nose, left mouth, right mouth. "Left"/"right" are
    /// on-screen, not anatomical — see the ordering fix in `fivePoints(from:imageSize:)`.
    private static let referencePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]
    private static let eyeReferencePoints = Array(referencePoints[0...1])

    /// Best-effort: 5-point landmarks, falling back to 2-point (eyes only), falling back to a padded crop.
    static func align(_ face: DetectedFace, from image: CGImage) -> AlignedFace? {
        let imageSize = CGSize(width: image.width, height: image.height)

        if let landmarks = face.landmarks,
           let points = fivePoints(from: landmarks, imageSize: imageSize),
           let warped = warp(image, sourcePoints: points, destinationPoints: referencePoints) {
            return AlignedFace(image: warped, tier: .fivePoint)
        }

        if let landmarks = face.landmarks,
           let eyes = twoPoints(from: landmarks, imageSize: imageSize),
           let warped = warp(image, sourcePoints: eyes, destinationPoints: eyeReferencePoints) {
            return AlignedFace(image: warped, tier: .twoPoint)
        }

        guard let cropped = FaceDetector.crop(face, from: image),
              let resized = resize(cropped, to: outputSize) else { return nil }
        return AlignedFace(image: resized, tier: .paddedCrop)
    }

    // MARK: - Landmark extraction
    //
    // Point/centroid/eye-center/transform math lives in `LandmarkGeometry`, shared with the liveness analyzer.

    private static func fivePoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let eyeA = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let eyeB = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize),
              let nose = landmarks.nose, let noseCenter = LandmarkGeometry.centroid(of: nose, imageSize: imageSize),
              let outerLips = landmarks.outerLips else { return nil }

        // Vision's leftEye/rightEye are anatomical, not on-screen — sort by x instead of trusting either label.
        let imageLeftEye = eyeA.x <= eyeB.x ? eyeA : eyeB
        let imageRightEye = eyeA.x <= eyeB.x ? eyeB : eyeA

        let lipPoints = LandmarkGeometry.imagePoints(of: outerLips, imageSize: imageSize)
        guard let imageLeftMouth = lipPoints.min(by: { $0.x < $1.x }),
              let imageRightMouth = lipPoints.max(by: { $0.x < $1.x }) else { return nil }

        return [imageLeftEye, imageRightEye, noseCenter, imageLeftMouth, imageRightMouth]
    }

    private static func twoPoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let eyeA = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let eyeB = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize) else { return nil }
        return eyeA.x <= eyeB.x ? [eyeA, eyeB] : [eyeB, eyeA]
    }

    // MARK: - Warp

    /// Points are given in top-left/y-down space but flipped before solving since CGContext is bottom-left/y-up;
    /// the image itself needs no flip since `CGContext.draw(_:in:)` already handles a CGImage's row order.
    private static func warp(_ image: CGImage, sourcePoints: [CGPoint], destinationPoints: [CGPoint]) -> CGImage? {
        let imageHeight = CGFloat(image.height)
        let sourceFlipped = sourcePoints.map { CGPoint(x: $0.x, y: imageHeight - $0.y) }
        let destinationFlipped = destinationPoints.map { CGPoint(x: $0.x, y: CGFloat(outputSize) - $0.y) }

        guard let transform = LandmarkGeometry.solveSimilarityTransform(from: sourceFlipped, to: destinationFlipped) else { return nil }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputSize, height: outputSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        return context.makeImage()
    }

    private static func resize(_ image: CGImage, to size: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}

// MARK: - ArcFace embedder

enum ArcFaceEmbedderError: LocalizedError {
    case modelNotFound
    case modelLoadFailed(String)
    case pixelBufferCreationFailed
    case unexpectedInputSize(got: (Int, Int), expected: Int)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "The face model (ArcFace.mlmodelc) is not installed. Build the app with scripts/package-app.sh, or place ArcFace.mlmodelc in ~/Library/Application Support/\(FaceUnlockPaths.appIdentifier)/."
        case .modelLoadFailed(let detail):
            return "The face model could not be loaded: \(detail)"
        case .pixelBufferCreationFailed:
            return "Could not prepare the face image for the model."
        case .unexpectedInputSize(let got, let expected):
            return "Face image must be \(expected)x\(expected), got \(got.0)x\(got.1)."
        case .unexpectedOutput(let detail):
            return "The face model produced unexpected output: \(detail)"
        }
    }
}

nonisolated enum FaceUnlockPaths {
    static let appIdentifier = "com.softlock.agent-shield"

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appIdentifier, isDirectory: true)
    }
}

/// 112x112 aligned RGB face -> 512-d L2-normalized embedding. Preprocessing ((px-127.5)/127.5,
/// RGB) is baked into the Core ML model; scripts/convert_arcface.py checks parity with ONNX.
nonisolated final class ArcFaceEmbedder: @unchecked Sendable {
    static let modelIdentifier = "arcface-w600k_mbf-v1"
    static let embeddingDimension = 512

    private static let inputSize = FaceAligner.outputSize
    private static let inputName = "input_image"
    private static let outputName = "embedding"

    private let model: MLModel
    private let pixelBufferPool: CVPixelBufferPool

    /// Bundle first (packaged app), then Application Support (manual install).
    static func locateModel() -> URL? {
        if let url = Bundle.main.url(forResource: "ArcFace", withExtension: "mlmodelc") {
            return url
        }
        let manual = FaceUnlockPaths.applicationSupportDirectory.appendingPathComponent("ArcFace.mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: manual.path) ? manual : nil
    }

    static var isModelAvailable: Bool { locateModel() != nil }

    init() throws {
        guard let modelURL = Self.locateModel() else { throw ArcFaceEmbedderError.modelNotFound }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ArcFaceEmbedderError.modelLoadFailed(error.localizedDescription)
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.inputSize,
            kCVPixelBufferHeightKey as String: Self.inputSize,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard let pool else { throw ArcFaceEmbedderError.pixelBufferCreationFailed }
        pixelBufferPool = pool
    }

    /// Blocking; call off the main actor.
    func embedding(for face: CGImage) throws -> [Float] {
        guard face.width == Self.inputSize, face.height == Self.inputSize else {
            throw ArcFaceEmbedderError.unexpectedInputSize(got: (face.width, face.height), expected: Self.inputSize)
        }
        var bufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &bufferOut) == kCVReturnSuccess,
              let pixelBuffer = bufferOut else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        try Self.render(face, into: pixelBuffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw ArcFaceEmbedderError.unexpectedOutput("no '\(Self.outputName)' output")
        }
        guard array.count == Self.embeddingDimension else {
            throw ArcFaceEmbedderError.unexpectedOutput("expected \(Self.embeddingDimension) floats, got \(array.count)")
        }
        var raw = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count { raw[i] = array[i].floatValue }
        return FaceMath.l2Normalized(raw)
    }

    private static func render(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

// MARK: - Pipeline

struct FaceRecognitionResult: @unchecked Sendable {
    let embedding: [Float]
    /// The 112x112 aligned crop the embedding came from; also used for sharpness / lighting checks.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let face: DetectedFace
}

enum FaceRecognitionError: LocalizedError {
    case alignmentFailed
    /// A 5-point alignment is required; the degraded fallbacks are too unreliable to unlock with.
    case unreliableAlignment

    var errorDescription: String? {
        switch self {
        case .alignmentFailed: return "Could not align the detected face."
        case .unreliableAlignment: return "Face landmarks were not reliable enough."
        }
    }
}

nonisolated enum FaceRecognitionPipeline {
    /// Faces narrower than this fraction of the frame are treated as bystanders.
    static let minimumProminentFaceWidth: CGFloat = 0.18
    private static let continuityDistanceTolerance: CGFloat = 0.3

    /// Detects, picks the person at the camera, aligns (5-point only) and embeds.
    /// Returns nil when no prominent face is present.
    static func recognize(
        in frame: CGImage,
        embedder: ArcFaceEmbedder,
        preferNear previous: CGRect? = nil
    ) throws -> FaceRecognitionResult? {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = selectDominantFace(in: faces, preferNear: previous) else { return nil }
        return try recognize(face, in: frame, embedder: embedder)
    }

    static func recognize(_ face: DetectedFace, in frame: CGImage, embedder: ArcFaceEmbedder) throws -> FaceRecognitionResult {
        guard let aligned = FaceAligner.align(face, from: frame) else { throw FaceRecognitionError.alignmentFailed }
        guard aligned.tier == .fivePoint else { throw FaceRecognitionError.unreliableAlignment }
        let embedding = try embedder.embedding(for: aligned.image)
        return FaceRecognitionResult(embedding: embedding, alignedImage: aligned.image, alignmentTier: aligned.tier, face: face)
    }

    static func selectDominantFace(in faces: [DetectedFace], preferNear previous: CGRect? = nil) -> DetectedFace? {
        let candidates = faces.filter { $0.normalizedBoundingBox.width >= minimumProminentFaceWidth }
        guard !candidates.isEmpty else { return nil }
        if let previous {
            let center = CGPoint(x: previous.midX, y: previous.midY)
            if let nearest = candidates.min(by: { distance($0, center) < distance($1, center) }),
               distance(nearest, center) < continuityDistanceTolerance {
                return nearest
            }
        }
        return candidates.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Largest face regardless of size — enrollment uses it to say "move closer" instead of "no face".
    static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    private static func distance(_ face: DetectedFace, _ point: CGPoint) -> CGFloat {
        hypot(face.normalizedBoundingBox.midX - point.x, face.normalizedBoundingBox.midY - point.y)
    }
}
