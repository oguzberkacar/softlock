import Foundation

// Pure, camera-free logic behind the guided face enrollment: which head directions are asked for,
// which yaw/pitch window counts as "turned enough", how a live pose maps to on-screen guidance,
// when a held pose becomes a capture, and how the finished capture set is sanity-checked.
//
// Pose bands and sign conventions follow jonnyoo/glance (MIT), see THIRD_PARTY_NOTICES.md.
// Vision reports yaw > 0 when the person turns toward THEIR left (screen-left on a mirrored
// preview) and pitch < 0 when they look up; glance verified both empirically.

// MARK: - Poses

/// Center plus the eight compass directions, in the order they are asked for.
public enum EnrollmentPose: Int, CaseIterable, Sendable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    public enum YawBand: Sendable { case left, none, right }
    public enum PitchBand: Sendable { case up, none, down }

    public var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: return .left
        case .right, .topRight, .bottomRight: return .right
        case .center, .top, .bottom: return .none
        }
    }

    public var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: return .up
        case .bottom, .bottomLeft, .bottomRight: return .down
        case .center, .left, .right: return .none
        }
    }

    /// Compass angle on the ring (0 = top, clockwise). `nil` for center, which has no sector.
    public var compassAngle: Double? {
        switch self {
        case .center: return nil
        case .left: return 270
        case .topLeft: return 315
        case .top: return 0
        case .topRight: return 45
        case .right: return 90
        case .bottomRight: return 135
        case .bottom: return 180
        case .bottomLeft: return 225
        }
    }

    public var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .left: return "Turn your head slightly left"
        case .topLeft: return "Turn your head to the top left"
        case .top: return "Tilt your head slightly up"
        case .topRight: return "Turn your head to the top right"
        case .right: return "Turn your head slightly right"
        case .bottomRight: return "Turn your head to the bottom right"
        case .bottom: return "Tilt your head slightly down"
        case .bottomLeft: return "Turn your head to the bottom left"
        }
    }

    /// Lower-case direction for feedback sentences ("turn a bit more to the left").
    public var directionName: String {
        switch self {
        case .center: return "center"
        case .left: return "left"
        case .topLeft: return "top left"
        case .top: return "up"
        case .topRight: return "top right"
        case .right: return "right"
        case .bottomRight: return "bottom right"
        case .bottom: return "down"
        case .bottomLeft: return "bottom left"
        }
    }

    /// Persisted next to each sample.
    public var id: String {
        switch self {
        case .center: return "center"
        case .left: return "left"
        case .topLeft: return "top_left"
        case .top: return "top"
        case .topRight: return "top_right"
        case .right: return "right"
        case .bottomRight: return "bottom_right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom_left"
        }
    }

    /// >1 relaxes this pose's bands. Looking down is physically harder to hold in front of a laptop camera.
    public var leniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: return 1.5
        case .bottom: return 1.2
        default: return 1
        }
    }

    /// The ring sector (0...7, 45 degrees each, 0 = top, clockwise) a ring tick at `angle` belongs to.
    public static func sector(forAngle angle: Double) -> Int {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return Int((positive / 45).rounded()) % 8
    }

    /// The pose owning a ring sector; center owns none.
    public static func pose(forSector sector: Int) -> EnrollmentPose? {
        let angle = Double(((sector % 8) + 8) % 8) * 45
        return allCases.first { $0.compassAngle == angle }
    }
}

// MARK: - Pose window

public struct EnrollmentPoseBands: Sendable, Equatable {
    /// Radians. Turn/tilt must exceed the inner threshold and stay under the outer cap.
    public var yawInner: Float = 0.25
    public var yawCenterTolerance: Float = 0.18
    public var yawOuterCap: Float = 1.2
    public var pitchInner: Float = 0.20
    public var pitchCenterTolerance: Float = 0.15
    public var pitchOuterCap: Float = 0.9

    public static let standard = EnrollmentPoseBands()
    /// After this long stuck on one pose the bands widen so an odd camera angle cannot strand the user.
    public static let stallTimeout: TimeInterval = 12
    public static let stallWidenFactor: Float = 1.25

    public init() {}
}

/// How a live head pose compares with what the current target asks for.
public enum PoseAssessment: Sendable, Equatable {
    case inWindow
    /// Facing the right way but not far enough yet.
    case needMore
    /// Turned past the outer cap (or, for center, not facing the camera).
    case tooFar
    /// Turned toward the opposite side.
    case wrongWay
    /// Correct on the requested axis, drifting on the one that should stay level.
    case offAxis
    /// Center target only: not looking straight at the camera.
    case notCentered
}

/// Where the head is pointing, on the same compass as `EnrollmentPose.compassAngle`.
public struct EnrollmentHeadTurn: Sendable, Equatable {
    public let angle: Double
    /// 0...1, reaching 1 as the current pose's window opens.
    public let progress: Double
}

public enum EnrollmentPoseEvaluator {
    public static func assess(
        yaw: Float,
        pitch: Float,
        pose: EnrollmentPose,
        widened: Bool = false,
        bands: EnrollmentPoseBands = .standard
    ) -> PoseAssessment {
        let factor = (widened ? EnrollmentPoseBands.stallWidenFactor : 1) * pose.leniency

        if pose == .center {
            let centered = abs(yaw) < bands.yawCenterTolerance * factor
                && abs(pitch) < bands.pitchCenterTolerance * factor
            return centered ? .inWindow : .notCentered
        }

        var wrong = false, over = false, off = false, short = false

        func judge(oriented: Float, inner: Float, cap: Float) {
            if oriented < -inner / factor * 0.5 { wrong = true }
            else if oriented >= cap { over = true }
            else if oriented <= inner / factor { short = true }
        }

        switch pose.yawBand {
        case .none: if abs(yaw) >= bands.yawCenterTolerance * factor { off = true }
        case .left: judge(oriented: yaw, inner: bands.yawInner, cap: bands.yawOuterCap)
        case .right: judge(oriented: -yaw, inner: bands.yawInner, cap: bands.yawOuterCap)
        }
        switch pose.pitchBand {
        case .none: if abs(pitch) >= bands.pitchCenterTolerance * factor { off = true }
        case .up: judge(oriented: -pitch, inner: bands.pitchInner, cap: bands.pitchOuterCap)
        case .down: judge(oriented: pitch, inner: bands.pitchInner, cap: bands.pitchOuterCap)
        }

        if wrong { return .wrongWay }
        if over { return .tooFar }
        if off { return .offAxis }
        if short { return .needMore }
        return .inWindow
    }

    /// Live head direction for the ring indicator, or nil for center / when it is just noise.
    public static func headTurn(
        yaw: Float,
        pitch: Float,
        pose: EnrollmentPose,
        bands: EnrollmentPoseBands = .standard
    ) -> EnrollmentHeadTurn? {
        guard pose != .center else { return nil }
        let x = Double(-yaw / (bands.yawInner / pose.leniency))
        let y = Double(-pitch / (bands.pitchInner / pose.leniency))
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > 0.15 else { return nil }
        let degrees = atan2(x, y) * 180 / .pi
        return EnrollmentHeadTurn(angle: degrees < 0 ? degrees + 360 : degrees, progress: min(magnitude, 1))
    }
}

// MARK: - Feedback

public enum EnrollmentRejection: Sendable, Equatable {
    case screenGlare
    case deviceInView
    case flatFace

    public var message: String {
        switch self {
        case .screenGlare: return "That frame looked like glare off a screen or photo. Face the camera in normal room light."
        case .deviceInView: return "A phone or screen edge is in view. Remove it so only your face is visible."
        case .flatFace: return "Your face looked flat, like a picture. Turn your head naturally in front of the camera."
        }
    }
}

public enum EnrollmentFeedback: Sendable, Equatable {
    public enum Tone: Sendable { case neutral, good, warning, error }

    case starting
    case noFace
    case multipleFaces
    case tooFar
    case tooClose
    case offCenter
    case tooDark
    case tooBright
    case blurry
    case lowQuality
    case poseUnreadable
    case lookStraight
    case turnMore(EnrollmentPose)
    case turnLess(EnrollmentPose)
    case wrongWay(EnrollmentPose)
    case keepLevel(EnrollmentPose)
    case holdStill
    case holding
    case captured
    case rejected(EnrollmentRejection)

    public var message: String {
        switch self {
        case .starting: return "Starting the camera. Hold still for a moment."
        case .noFace: return "Move into view. No face found."
        case .multipleFaces: return "Only one face should be in view."
        case .tooFar: return "Move closer to the camera."
        case .tooClose: return "Move back a little. You are too close."
        case .offCenter: return "Center your face inside the circle."
        case .tooDark: return "Too dark. Face a light source or turn on a light."
        case .tooBright: return "Too bright. Avoid a window or lamp directly behind or in front of you."
        case .blurry: return "The image is blurry. Hold still and clean the camera lens."
        case .lowQuality: return "Poor picture quality. Improve the lighting and hold still."
        case .poseUnreadable: return "Cannot read your head angle. Face the camera and keep your whole face visible."
        case .lookStraight: return "Face the camera directly, then hold still."
        case .turnMore(let pose): return "Keep turning \(pose.directionName), a little more."
        case .turnLess(let pose): return "That is too far. Ease back toward \(pose.directionName), just slightly."
        case .wrongWay(let pose): return "Other way. Turn toward \(pose.directionName)."
        case .keepLevel(let pose): return "Keep your head level while you turn \(pose.directionName)."
        case .holdStill: return "Hold still."
        case .holding: return "Good. Hold this position."
        case .captured: return "Captured."
        case .rejected(let reason): return reason.message
        }
    }

    public var tone: Tone {
        switch self {
        case .starting, .holding, .holdStill, .turnMore, .lookStraight: return .neutral
        case .captured: return .good
        case .noFace, .multipleFaces, .tooFar, .tooClose, .offCenter, .tooDark, .tooBright, .blurry, .lowQuality,
             .poseUnreadable, .turnLess, .wrongWay, .keepLevel:
            return .warning
        case .rejected: return .error
        }
    }

    /// Feedback for a pose that is not (yet) in the accepted window.
    public static func forPose(_ assessment: PoseAssessment, pose: EnrollmentPose) -> EnrollmentFeedback {
        switch assessment {
        case .inWindow: return .holding
        case .needMore: return .turnMore(pose)
        case .tooFar: return .turnLess(pose)
        case .wrongWay: return .wrongWay(pose)
        case .offAxis: return .keepLevel(pose)
        case .notCentered: return .lookStraight
        }
    }
}

// MARK: - Progress and capture timing

/// Which pose is being captured, how many samples it has, and overall completion.
public struct EnrollmentProgress: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case sample
        case poseCompleted(EnrollmentPose, allDone: Bool)
    }

    public static let defaultSamplesPerPose = 3

    public let samplesPerPose: Int
    public private(set) var poseIndex = 0
    public private(set) var capturedInCurrent = 0
    public private(set) var completedPoses: Set<EnrollmentPose> = []

    public init(samplesPerPose: Int = EnrollmentProgress.defaultSamplesPerPose) {
        self.samplesPerPose = max(samplesPerPose, 1)
    }

    public var currentPose: EnrollmentPose? {
        EnrollmentPose(rawValue: poseIndex)
    }

    public var isComplete: Bool { poseIndex >= EnrollmentPose.allCases.count }
    public var totalSamples: Int { EnrollmentPose.allCases.count * samplesPerPose }
    public var capturedSamples: Int { min(poseIndex * samplesPerPose + capturedInCurrent, totalSamples) }
    public var fraction: Double { Double(capturedSamples) / Double(totalSamples) }

    @discardableResult
    public mutating func recordSample() -> Event? {
        guard let pose = currentPose else { return nil }
        capturedInCurrent += 1
        guard capturedInCurrent >= samplesPerPose else { return .sample }
        completedPoses.insert(pose)
        poseIndex += 1
        capturedInCurrent = 0
        return .poseCompleted(pose, allDone: isComplete)
    }
}

/// Turns "the pose is acceptable this frame" into "take a sample now": the pose must stay
/// acceptable for a short hold and a few consecutive frames, and samples are spaced apart.
public struct EnrollmentCaptureGate: Sendable {
    public var holdDuration: TimeInterval
    public var requiredStreak: Int
    public var minimumInterval: TimeInterval

    private var holdStart: TimeInterval?
    private var streak = 0
    private var lastCapture: TimeInterval = -.infinity

    public init(holdDuration: TimeInterval = 0.4, requiredStreak: Int = 2, minimumInterval: TimeInterval = 0.35) {
        self.holdDuration = holdDuration
        self.requiredStreak = max(requiredStreak, 1)
        self.minimumInterval = minimumInterval
    }

    public mutating func reset() {
        holdStart = nil
        streak = 0
    }

    /// 0...1 progress through the initial hold, for a "hold still" hint.
    public func holdProgress(now: TimeInterval) -> Double {
        guard let holdStart, holdDuration > 0 else { return 0 }
        return min(max((now - holdStart) / holdDuration, 0), 1)
    }

    /// Returns true when a sample should be taken for this frame.
    public mutating func observe(accepted: Bool, now: TimeInterval) -> Bool {
        guard accepted else {
            reset()
            return false
        }
        if holdStart == nil { holdStart = now }
        streak += 1
        guard let holdStart, now - holdStart >= holdDuration,
              streak >= requiredStreak,
              now - lastCapture >= minimumInterval else { return false }
        lastCapture = now
        streak = 0
        return true
    }
}

// MARK: - Frame quality

/// Where the face sat in a frame, in Vision's normalized units.
public struct FaceBoxSample: Sendable, Equatable {
    public let midX: Double
    public let midY: Double
    public let width: Double

    public init(midX: Double, midY: Double, width: Double) {
        self.midX = midX
        self.midY = midY
        self.width = width
    }

    /// True when the face barely moved between two analysed frames (rejects motion blur).
    public func isSteady(since previous: FaceBoxSample, tolerance: Double = 0.03) -> Bool {
        let moved = hypot(midX - previous.midX, midY - previous.midY)
        let scaled = abs(width - previous.width)
        return moved <= tolerance && scaled <= tolerance
    }
}

public enum FaceFramePlacement: Sendable, Equatable {
    case ok, tooFar, tooClose, offCenter

    public static let minimumFaceWidth = 0.12
    public static let maximumFaceWidth = 0.62

    public static func assess(_ box: FaceBoxSample) -> FaceFramePlacement {
        if box.width < minimumFaceWidth { return .tooFar }
        if box.width > maximumFaceWidth { return .tooClose }
        if box.midX < 0.25 || box.midX > 0.75 || box.midY < 0.15 || box.midY > 0.85 { return .offCenter }
        return .ok
    }
}

/// Cheap lighting / focus checks on a small grayscale face crop.
public enum FaceImageQuality: Sendable, Equatable {
    case ok, tooDark, tooBright, blurry

    public static let darkLuma = 45.0
    public static let brightLuma = 232.0
    /// Variance of the 4-neighbour Laplacian on a ~80 px face crop. A clearly blurred crop sits
    /// in single digits; this is a floor for obviously unusable frames, not a sharpness target.
    public static let minimumSharpness = 10.0

    public static func meanLuma(_ luma: [UInt8]) -> Double {
        guard !luma.isEmpty else { return 0 }
        return Double(luma.reduce(0) { $0 + Int($1) }) / Double(luma.count)
    }

    public static func laplacianVariance(luma: [UInt8], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, luma.count >= width * height else { return 0 }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let value = Double(luma[i - 1]) + Double(luma[i + 1]) + Double(luma[i - width]) + Double(luma[i + width])
                    - 4 * Double(luma[i])
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    public static func assess(luma: [UInt8], width: Int, height: Int) -> FaceImageQuality {
        let mean = meanLuma(luma)
        if mean < darkLuma { return .tooDark }
        if mean > brightLuma { return .tooBright }
        if laplacianVariance(luma: luma, width: width, height: height) < minimumSharpness { return .blurry }
        return .ok
    }
}

// MARK: - Capture-set consistency

/// Sanity-checks a finished capture set. Every frame sees the same person only if the center
/// frames agree with each other and the turned frames stay in the same identity neighbourhood.
public enum FaceEnrollmentConsistency: Sendable, Equatable {
    /// `keepOthers[i]` is false for a non-center sample dropped as an outlier.
    case ok(keepOthers: [Bool])
    case centerInconsistent
    case tooManyOutliers

    public static let minimumCenterAgreement: Float = 0.6
    public static let minimumTurnedAgreement: Float = 0.25
    public static let maximumOutlierFraction = 0.2

    public static func evaluate(center: [[Float]], others: [[Float]]) -> FaceEnrollmentConsistency {
        guard let centroid = FaceMath.average(center), !center.isEmpty else { return .centerInconsistent }
        let weakestCenter = center.map { FaceMath.cosineSimilarity($0, centroid) }.min() ?? 0
        guard weakestCenter >= minimumCenterAgreement else { return .centerInconsistent }

        let keep = others.map { FaceMath.cosineSimilarity($0, centroid) >= minimumTurnedAgreement }
        let dropped = keep.filter { !$0 }.count
        if !others.isEmpty, Double(dropped) / Double(others.count) > maximumOutlierFraction { return .tooManyOutliers }
        return .ok(keepOthers: keep)
    }
}
