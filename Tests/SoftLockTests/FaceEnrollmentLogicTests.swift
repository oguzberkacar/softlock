import Testing
@testable import SoftLockCore

@Test func sectorsMapCompassAnglesToPoses() {
    #expect(EnrollmentPose.sector(forAngle: 0) == 0)
    #expect(EnrollmentPose.sector(forAngle: 359) == 0)
    #expect(EnrollmentPose.sector(forAngle: 270) == 6)
    #expect(EnrollmentPose.pose(forSector: 6) == .left)
    #expect(EnrollmentPose.pose(forSector: 0) == .top)
    #expect(EnrollmentPose.pose(forSector: 2) == .right)
    #expect(EnrollmentPose.pose(forSector: 4) == .bottom)
    // Every non-center pose owns exactly one sector; center owns none.
    let owned = EnrollmentPose.allCases.compactMap { $0.compassAngle }.map { EnrollmentPose.sector(forAngle: $0) }
    #expect(Set(owned).count == 8)
    #expect(EnrollmentPose.center.compassAngle == nil)
}

@Test func centerPoseNeedsAFrontalFace() {
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.05, pitch: -0.05, pose: .center) == .inWindow)
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.4, pitch: 0, pose: .center) == .notCentered)
}

@Test func yawSignFollowsVisionConvention() {
    // Vision: +yaw = user's left.
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.4, pitch: 0, pose: .left) == .inWindow)
    #expect(EnrollmentPoseEvaluator.assess(yaw: -0.4, pitch: 0, pose: .right) == .inWindow)
    #expect(EnrollmentPoseEvaluator.assess(yaw: -0.4, pitch: 0, pose: .left) == .wrongWay)
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.1, pitch: 0, pose: .left) == .needMore)
    #expect(EnrollmentPoseEvaluator.assess(yaw: 1.4, pitch: 0, pose: .left) == .tooFar)
}

@Test func pitchSignFollowsVisionConvention() {
    // Vision: negative pitch = looking up.
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0, pitch: -0.3, pose: .top) == .inWindow)
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0, pitch: 0.3, pose: .bottom) == .inWindow)
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0, pitch: 0.3, pose: .top) == .wrongWay)
}

@Test func straightAxisMustStayLevel() {
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.4, pitch: 0.4, pose: .left) == .offAxis)
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.4, pitch: -0.3, pose: .topLeft) == .inWindow)
    #expect(EnrollmentPoseEvaluator.assess(yaw: -0.4, pitch: 0.3, pose: .bottomRight) == .inWindow)
}

@Test func stallingWidensTheWindow() {
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.21, pitch: 0, pose: .left) == .needMore)
    #expect(EnrollmentPoseEvaluator.assess(yaw: 0.21, pitch: 0, pose: .left, widened: true) == .inWindow)
}

@Test func headTurnPointsAtTheCompassDirection() throws {
    let left = try #require(EnrollmentPoseEvaluator.headTurn(yaw: 0.25, pitch: 0, pose: .left))
    #expect(abs(left.angle - 270) < 0.001)
    #expect(abs(left.progress - 1) < 0.001)
    let up = try #require(EnrollmentPoseEvaluator.headTurn(yaw: 0, pitch: -0.1, pose: .top))
    #expect(abs(up.angle - 0) < 0.001 || abs(up.angle - 360) < 0.001)
    #expect(EnrollmentPoseEvaluator.headTurn(yaw: 0.01, pitch: 0.01, pose: .left) == nil)
    #expect(EnrollmentPoseEvaluator.headTurn(yaw: 0.5, pitch: 0, pose: .center) == nil)
}

@Test func progressWalksAllPosesAndReports() {
    var progress = EnrollmentProgress(samplesPerPose: 2)
    #expect(progress.currentPose == .center)
    #expect(progress.totalSamples == 18)
    #expect(progress.recordSample() == .sample)
    #expect(progress.recordSample() == .poseCompleted(.center, allDone: false))
    #expect(progress.currentPose == .left)
    #expect(progress.completedPoses == [.center])
    for _ in 0..<14 { progress.recordSample() }
    #expect(progress.currentPose == .bottomLeft)
    #expect(progress.recordSample() == .sample)
    #expect(progress.recordSample() == .poseCompleted(.bottomLeft, allDone: true))
    #expect(progress.isComplete)
    #expect(progress.fraction == 1)
    #expect(progress.recordSample() == nil)
}

private func feed(_ gate: inout EnrollmentCaptureGate, _ accepted: Bool, _ now: Double) -> Bool {
    gate.observe(accepted: accepted, now: now)
}

@Test func captureGateNeedsHoldStreakAndSpacing() {
    var gate = EnrollmentCaptureGate(holdDuration: 0.4, requiredStreak: 2, minimumInterval: 0.35)
    #expect(!feed(&gate, true, 0))
    #expect(!feed(&gate, true, 0.2))   // hold not reached
    #expect(feed(&gate, true, 0.45))
    #expect(!feed(&gate, true, 0.5))   // streak restarted
    #expect(!feed(&gate, true, 0.7))   // spacing not reached (0.25 since capture)
    #expect(feed(&gate, true, 0.9))
    #expect(!feed(&gate, false, 1.0))  // dropping the pose resets the hold
    #expect(!feed(&gate, true, 1.1))
    #expect(!feed(&gate, true, 1.3))
    #expect(feed(&gate, true, 1.6))
}

@Test func steadinessAndPlacement() {
    let a = FaceBoxSample(midX: 0.5, midY: 0.5, width: 0.3)
    #expect(FaceBoxSample(midX: 0.51, midY: 0.5, width: 0.3).isSteady(since: a))
    #expect(!FaceBoxSample(midX: 0.6, midY: 0.5, width: 0.3).isSteady(since: a))
    #expect(FaceFramePlacement.assess(a) == .ok)
    #expect(FaceFramePlacement.assess(FaceBoxSample(midX: 0.5, midY: 0.5, width: 0.1)) == .tooFar)
    #expect(FaceFramePlacement.assess(FaceBoxSample(midX: 0.5, midY: 0.5, width: 0.8)) == .tooClose)
    #expect(FaceFramePlacement.assess(FaceBoxSample(midX: 0.9, midY: 0.5, width: 0.3)) == .offCenter)
}

@Test func imageQualityCatchesDarkBrightAndFlat() {
    let side = 16
    let dark = [UInt8](repeating: 10, count: side * side)
    let bright = [UInt8](repeating: 250, count: side * side)
    let flat = [UInt8](repeating: 128, count: side * side)
    let checker = (0..<(side * side)).map { ($0 % side + $0 / side) % 2 == 0 ? UInt8(60) : UInt8(200) }
    #expect(FaceImageQuality.assess(luma: dark, width: side, height: side) == .tooDark)
    #expect(FaceImageQuality.assess(luma: bright, width: side, height: side) == .tooBright)
    #expect(FaceImageQuality.assess(luma: flat, width: side, height: side) == .blurry)
    #expect(FaceImageQuality.assess(luma: checker, width: side, height: side) == .ok)
}

@Test func consistencyRejectsForeignFacesAndKeepsGoodOnes() {
    let center: [[Float]] = [[1, 0, 0], [0.98, 0.1, 0], [0.99, 0, 0.1]]
    let good: [Float] = [0.8, 0.5, 0]
    let stranger: [Float] = [0, 0, 1]

    guard case .ok(let mask) = FaceEnrollmentConsistency.evaluate(center: center, others: [good, good, good, good, good, good]) else {
        Issue.record("expected ok")
        return
    }
    #expect(mask.allSatisfy { $0 })

    #expect(FaceEnrollmentConsistency.evaluate(center: center, others: [good, stranger, stranger]) == .tooManyOutliers)
    #expect(FaceEnrollmentConsistency.evaluate(center: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], others: [good]) == .centerInconsistent)
    #expect(FaceEnrollmentConsistency.evaluate(center: [], others: [good]) == .centerInconsistent)
}

@Test func feedbackCoversEveryAssessmentWithReadableText() {
    for assessment in [PoseAssessment.inWindow, .needMore, .tooFar, .wrongWay, .offAxis, .notCentered] {
        for pose in EnrollmentPose.allCases {
            #expect(!EnrollmentFeedback.forPose(assessment, pose: pose).message.isEmpty)
        }
    }
    #expect(EnrollmentFeedback.noFace.message.contains("Move into view"))
    #expect(EnrollmentFeedback.rejected(.flatFace).tone == .error)
}
