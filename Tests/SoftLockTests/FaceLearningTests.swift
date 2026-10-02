import Testing
@testable import SoftLockCore

struct FaceLearningTests {
    private func unit(_ values: [Float]) -> [Float] { FaceMath.l2Normalized(values) }
    private var owner: FaceTemplate { FaceTemplate(samples: [unit([1, 0, 0, 0]), unit([0.9, 0.1, 0, 0])])! }

    @Test func refusesWithoutATemplate() {
        #expect(FaceLearning.check(unit([1, 0, 0, 0]), against: nil) == .notEnrolled)
    }

    @Test func refusesAStranger() {
        #expect(FaceLearning.check(unit([0, 1, 0, 0]), against: owner) == .differentFace)
    }

    @Test func refusesAnExactDuplicate() {
        #expect(FaceLearning.check(unit([1, 0, 0, 0]), against: owner) == .duplicate)
    }

    @Test func acceptsAHardButGenuineFrame() {
        // cosine to the centroid is about 0.6: well under the unlock threshold, over the learn floor.
        #expect(FaceLearning.check(unit([0.6, 0.8, 0, 0]), against: owner) == nil)
    }

    @Test func trimsOldestLearnedFirstAndNeverGuided() {
        struct S: Equatable { let id: Int; let learned: Bool }
        var samples = (0..<3).map { S(id: $0, learned: false) }
        for i in 0..<(FaceLearning.maximumLearnedSamples + 3) {
            samples = FaceLearning.appending(S(id: 100 + i, learned: true), to: samples, isLearned: \.learned)
        }
        #expect(samples.filter { !$0.learned }.count == 3)
        #expect(samples.filter(\.learned).count == FaceLearning.maximumLearnedSamples)
        #expect(samples.filter(\.learned).first?.id == 103)
    }
}
