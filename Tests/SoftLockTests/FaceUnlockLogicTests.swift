import Testing
@testable import SoftLockCore

private func close(_ a: Float, _ b: Float, _ tolerance: Float = 1e-5) -> Bool {
    abs(a - b) <= tolerance
}

@Test func cosineSimilarityBasics() {
    #expect(close(FaceMath.cosineSimilarity([1, 0], [1, 0]), 1))
    #expect(close(FaceMath.cosineSimilarity([1, 0], [0, 1]), 0))
    #expect(close(FaceMath.cosineSimilarity([1, 0], [-1, 0]), -1))
    #expect(close(FaceMath.cosineSimilarity([2, 0], [5, 0]), 1))
}

@Test func cosineSimilarityDegenerateInputsNeverMatch() {
    #expect(FaceMath.cosineSimilarity([], []) == 0)
    #expect(FaceMath.cosineSimilarity([1, 2], [1]) == 0)
    #expect(FaceMath.cosineSimilarity([0, 0], [1, 1]) == 0)
}

@Test func averageIsUnitLengthAndIgnoresMagnitude() throws {
    let mean = try #require(FaceMath.average([[100, 0], [0, 1]]))
    #expect(close(mean[0], mean[1]))
    #expect(close(mean.reduce(0) { $0 + $1 * $1 }, 1))
    #expect(FaceMath.average([]) == nil)
}

@Test func thresholdRequiresBothCentroidAndSample() {
    let policy = FaceMatchPolicy(threshold: 0.66)
    #expect(policy.isMatch(FaceMatchScore(centroidSimilarity: 0.7, maxSampleSimilarity: 0.8)))
    #expect(policy.isMatch(FaceMatchScore(centroidSimilarity: 0.66, maxSampleSimilarity: 0.66)))
    #expect(!policy.isMatch(FaceMatchScore(centroidSimilarity: 0.7, maxSampleSimilarity: 0.6)))
    #expect(!policy.isMatch(FaceMatchScore(centroidSimilarity: 0.6, maxSampleSimilarity: 0.9)))
}

@Test func thresholdCannotBeLoweredBelowFloor() {
    #expect(FaceMatchPolicy(threshold: 0.1).threshold == FaceMatchPolicy.minimumThreshold)
    #expect(FaceMatchPolicy(threshold: .nan).threshold == FaceMatchPolicy.defaultThreshold)
}

@Test func scoreAgainstTemplate() throws {
    let template = try #require(FaceTemplate(samples: [[1, 0, 0], [0.9, 0.1, 0]]))
    let policy = FaceMatchPolicy(threshold: 0.9)
    #expect(policy.isMatch(policy.score([1, 0.05, 0], against: template)))
    #expect(!policy.isMatch(policy.score([0, 1, 0], against: template)))
}

@Test func deciderUnlocksOnlyWithStreakAndLiveness() {
    var decider = FaceScanDecider(requiredMatches: 3, wrongFaceLimit: 4)
    let live = FaceScanObservation.face(matched: true, liveness: .confirmed)
    let pending = FaceScanObservation.face(matched: true, liveness: .pending)

    #expect(decider.observe(pending) == .pending)
    #expect(decider.observe(pending) == .pending)
    // Streak reached but liveness still pending: no unlock.
    #expect(decider.observe(pending) == .pending)
    #expect(decider.observe(live) == .unlock)
}

@Test func deciderMismatchResetsStreak() {
    var decider = FaceScanDecider(requiredMatches: 3, wrongFaceLimit: 10)
    let good = FaceScanObservation.face(matched: true, liveness: .confirmed)
    let bad = FaceScanObservation.face(matched: false, liveness: .confirmed)
    _ = decider.observe(good)
    _ = decider.observe(good)
    #expect(decider.observe(bad) == .pending)
    #expect(decider.observe(good) == .pending)
    #expect(decider.observe(good) == .pending)
    #expect(decider.observe(good) == .unlock)
}

@Test func deciderRejectsAfterWrongFaceStreak() {
    var decider = FaceScanDecider(requiredMatches: 3, wrongFaceLimit: 3)
    let bad = FaceScanObservation.face(matched: false, liveness: .confirmed)
    #expect(decider.observe(bad) == .pending)
    #expect(decider.observe(bad) == .pending)
    #expect(decider.observe(bad) == .rejectedWrongFace)
}

@Test func spoofDenialOverridesMatch() {
    var decider = FaceScanDecider(requiredMatches: 2, wrongFaceLimit: 3)
    _ = decider.observe(.face(matched: true, liveness: .confirmed))
    #expect(decider.observe(.face(matched: true, liveness: .denied)) == .rejectedSpoof)
}

@Test func noFaceBreaksStreak() {
    var decider = FaceScanDecider(requiredMatches: 2, wrongFaceLimit: 3)
    let good = FaceScanObservation.face(matched: true, liveness: .confirmed)
    _ = decider.observe(good)
    #expect(decider.observe(.noFace) == .pending)
    #expect(decider.noFaceStreak == 1)
    #expect(decider.observe(good) == .pending)
    #expect(decider.observe(good) == .unlock)
}

@Test func throttleBlocksAfterMaxFailuresAndResets() {
    var throttle = FaceUnlockThrottle(maxFailures: 3)
    #expect(!throttle.isBlocked)
    throttle.recordFailure()
    throttle.recordFailure()
    #expect(!throttle.isBlocked)
    #expect(throttle.remainingAttempts == 1)
    throttle.recordFailure()
    #expect(throttle.isBlocked)
    throttle.recordFailure()
    #expect(throttle.consecutiveFailures == 3)
    throttle.reset()
    #expect(!throttle.isBlocked)
}

@Test func unjudgeableFramesAreSkippedNotAccepted() {
    #expect(!FaceScanFrameGate.isUnjudgeable(quality: 0.6, yaw: 0.1, pitch: 0.1))
    #expect(!FaceScanFrameGate.isUnjudgeable(quality: nil, yaw: nil, pitch: nil))
    #expect(FaceScanFrameGate.isUnjudgeable(quality: 0.1, yaw: 0, pitch: 0))
    #expect(FaceScanFrameGate.isUnjudgeable(quality: 0.6, yaw: -0.7, pitch: 0))
    #expect(FaceScanFrameGate.isUnjudgeable(quality: 0.6, yaw: 0, pitch: 0.6))
}

@Test func awaitingLivenessOnceMatchesReachedButLivenessPending() {
    var decider = FaceScanDecider(requiredMatches: 3, wrongFaceLimit: 10)
    let pending = FaceScanObservation.face(matched: true, liveness: .pending)
    #expect(!decider.isAwaitingLiveness)
    _ = decider.observe(pending)
    _ = decider.observe(pending)
    #expect(decider.observe(pending) == .pending)
    #expect(decider.isAwaitingLiveness)
    // The moment liveness confirms, the same streak unlocks.
    #expect(decider.observe(.face(matched: true, liveness: .confirmed)) == .unlock)
}

@Test func stillOwnerWithPendingLivenessIsAPromptNotAMiss() {
    let outcome = FaceScanTimeoutOutcome.classify(sawFace: true, judgedFrames: 40, awaitingLiveness: true)
    #expect(outcome == .needsLiveness)
    #expect(!outcome.countsAsMiss)
}

@Test func timeoutClassificationOnlyCountsJudgedNonMatches() {
    #expect(FaceScanTimeoutOutcome.classify(sawFace: false, judgedFrames: 0, awaitingLiveness: false) == .noFace)
    #expect(FaceScanTimeoutOutcome.classify(sawFace: true, judgedFrames: 0, awaitingLiveness: false) == .noClearFrame)
    let miss = FaceScanTimeoutOutcome.classify(sawFace: true, judgedFrames: 12, awaitingLiveness: false)
    #expect(miss == .notRecognized)
    #expect(miss.countsAsMiss)
    #expect(!FaceScanTimeoutOutcome.noFace.countsAsMiss)
    #expect(!FaceScanTimeoutOutcome.noClearFrame.countsAsMiss)
}
