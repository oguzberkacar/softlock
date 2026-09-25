import Foundation

// Pure, camera-free logic behind the optional "Unlock with Face" feature. Everything that
// touches Vision, Core ML, AVFoundation or AppKit lives in the SoftLock target; the decisions
// that gate an unlock live here so they can be unit tested.
//
// Cosine-similarity / averaging math is adapted from jonnyoo/glance (MIT), see
// THIRD_PARTY_NOTICES.md.

public enum FaceMath {
    /// Scales `vector` to unit length. Returns the input unchanged for a zero vector.
    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity in -1...1. Mismatched or empty vectors score 0 (never a match).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Normalizes each vector, averages them, then re-normalizes, so a large-magnitude sample
    /// cannot dominate the template. Vectors whose length differs from the first are ignored.
    public static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        var used = 0
        for vector in vectors where vector.count == first.count {
            let normalized = l2Normalized(vector)
            for i in 0..<normalized.count { sum[i] += normalized[i] }
            used += 1
        }
        guard used > 0 else { return nil }
        return l2Normalized(sum.map { $0 / Float(used) })
    }
}

/// The enrolled face: the averaged template plus every individual sample.
public struct FaceTemplate: Sendable, Equatable {
    public let centroid: [Float]
    public let samples: [[Float]]

    public init?(samples: [[Float]]) {
        guard let centroid = FaceMath.average(samples) else { return nil }
        self.centroid = centroid
        self.samples = samples.map(FaceMath.l2Normalized)
    }
}

public struct FaceMatchScore: Sendable, Equatable {
    public let centroidSimilarity: Float
    public let maxSampleSimilarity: Float
}

public struct FaceMatchPolicy: Sendable, Equatable {
    /// ArcFace w600k_mbf same-person scores are typically 0.5-0.8; strangers sit near 0-0.3.
    /// 0.66 is the value glance ships; it is deliberately on the strict side.
    public static let defaultThreshold: Float = 0.66
    /// Callers cannot configure below this, even by editing defaults by hand.
    public static let minimumThreshold: Float = 0.55

    public let threshold: Float

    public init(threshold: Float = FaceMatchPolicy.defaultThreshold) {
        self.threshold = max(threshold.isNaN ? Self.defaultThreshold : threshold, Self.minimumThreshold)
    }

    public func score(_ embedding: [Float], against template: FaceTemplate) -> FaceMatchScore {
        let centroid = FaceMath.cosineSimilarity(embedding, template.centroid)
        let best = template.samples.map { FaceMath.cosineSimilarity(embedding, $0) }.max() ?? centroid
        return FaceMatchScore(centroidSimilarity: centroid, maxSampleSimilarity: best)
    }

    /// A match needs BOTH the template and at least one individual sample to clear the
    /// threshold, so neither a blurred average nor a single lucky sample is enough alone.
    public func isMatch(_ score: FaceMatchScore) -> Bool {
        score.centroidSimilarity >= threshold && score.maxSampleSimilarity >= threshold
    }
}

public enum FaceLivenessVerdict: Sendable, Equatable {
    case pending
    case confirmed
    case denied
}

public enum FaceScanObservation: Sendable, Equatable {
    case noFace
    case face(matched: Bool, liveness: FaceLivenessVerdict)
}

public enum FaceScanDecision: Sendable, Equatable {
    case pending
    case unlock
    case rejectedWrongFace
    case rejectedSpoof
}

/// Per-scan state machine. Unlock needs a run of consecutive matching frames while liveness
/// is confirmed; a liveness denial or a run of non-matching frames ends the scan as a failure.
public struct FaceScanDecider: Sendable {
    public static let defaultRequiredMatches = 4
    public static let defaultWrongFaceLimit = 6

    public let requiredMatches: Int
    public let wrongFaceLimit: Int
    public private(set) var matchStreak = 0
    public private(set) var wrongStreak = 0
    public private(set) var noFaceStreak = 0

    public init(
        requiredMatches: Int = FaceScanDecider.defaultRequiredMatches,
        wrongFaceLimit: Int = FaceScanDecider.defaultWrongFaceLimit
    ) {
        self.requiredMatches = max(requiredMatches, 2)
        self.wrongFaceLimit = max(wrongFaceLimit, 1)
    }

    public mutating func reset() {
        matchStreak = 0
        wrongStreak = 0
        noFaceStreak = 0
    }

    /// True once enough consecutive frames matched that only the liveness proof (blink or a
    /// slight head turn) is still missing. The owner is there; they just have not moved yet.
    public var isAwaitingLiveness: Bool { matchStreak >= requiredMatches }

    public mutating func observe(_ observation: FaceScanObservation) -> FaceScanDecision {
        switch observation {
        case .noFace:
            noFaceStreak += 1
            matchStreak = 0
            wrongStreak = 0
            return .pending

        case .face(let matched, let liveness):
            noFaceStreak = 0
            // A spoof tell overrides everything, including a perfect match.
            if liveness == .denied { return .rejectedSpoof }

            if matched {
                matchStreak += 1
                wrongStreak = 0
            } else {
                matchStreak = 0
                wrongStreak += 1
                if wrongStreak >= wrongFaceLimit { return .rejectedWrongFace }
                return .pending
            }

            if matchStreak >= requiredMatches, liveness == .confirmed { return .unlock }
            return .pending
        }
    }
}

/// Counts failed face scans. After `maxFailures` in a row face unlock stays off until the
/// user gets in some other way (password, PIN, recovery code), which calls `reset()`.
public struct FaceUnlockThrottle: Sendable, Equatable {
    public static let defaultMaxFailures = 10

    public let maxFailures: Int
    public private(set) var consecutiveFailures = 0

    public init(maxFailures: Int = FaceUnlockThrottle.defaultMaxFailures) {
        self.maxFailures = max(maxFailures, 1)
    }

    public var isBlocked: Bool { consecutiveFailures >= maxFailures }
    public var remainingAttempts: Int { max(maxFailures - consecutiveFailures, 0) }

    public mutating func recordFailure() {
        consecutiveFailures = min(consecutiveFailures + 1, maxFailures)
    }

    public mutating func reset() {
        consecutiveFailures = 0
    }
}

/// Decides which frames are too poor to judge a match on. They are skipped, never accepted,
/// so this can only slow an unlock down, not let the wrong face in.
public enum FaceScanFrameGate {
    /// Same floor glance uses for capture quality.
    public static let minimumQuality: Float = 0.2
    public static let maximumYaw: Float = 0.5
    public static let maximumPitch: Float = 0.45

    public static func isUnjudgeable(quality: Float?, yaw: Float?, pitch: Float?) -> Bool {
        if let quality, quality < minimumQuality { return true }
        if let yaw, abs(yaw) > maximumYaw { return true }
        if let pitch, abs(pitch) > maximumPitch { return true }
        return false
    }
}

/// How a scan that ran out of time (no unlock, no outright rejection) should be reported.
/// Only `.notRecognized` is a miss that counts toward the pause; the others are prompts.
public enum FaceScanTimeoutOutcome: Sendable, Equatable {
    /// Nobody in front of the camera. Not an attack, never counted.
    case noFace
    /// A face was seen but never in a state that could be judged (angle / blur). Never counted.
    case noClearFrame
    /// The face matched but no blink or head turn was seen. Prompt the user; never counted.
    case needsLiveness
    /// A judgeable face was seen and did not match. Counts as one miss.
    case notRecognized

    public var countsAsMiss: Bool { self == .notRecognized }

    /// Prompt-only cycles allowed in a row before face unlock stops offering itself.
    public static let maximumPromptCycles = 3

    public static func classify(sawFace: Bool, judgedFrames: Int, awaitingLiveness: Bool) -> FaceScanTimeoutOutcome {
        if !sawFace { return .noFace }
        if judgedFrames == 0 { return .noClearFrame }
        if awaitingLiveness { return .needsLiveness }
        return .notRecognized
    }
}
