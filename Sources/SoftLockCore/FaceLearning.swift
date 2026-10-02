//
//  FaceLearning.swift
//
//  Rules for growing the enrolled face with scans the owner approved. Pure logic so the
//  safety limits are unit tested: a mis-click on a stranger's scan must not teach the model
//  to accept them, and learning must not grow the template without bound.
//

import Foundation

public enum FaceLearning {
    /// An approved scan must still look like the enrolled face. A stranger scores about 0-0.3
    /// against the template and the owner at a bad angle about 0.4-0.6, so 0.40 admits the
    /// hard-but-genuine frames (the point of learning) and refuses someone else.
    public static let minimumSimilarityToLearn: Float = 0.40

    /// Learned samples kept on top of the guided enrollment. Oldest learned samples drop first.
    public static let maximumLearnedSamples = 24

    /// Pose label stored with learned samples, to tell them from guided-capture samples.
    public static let learnedPose = "learned"

    public enum Refusal: Equatable, Sendable {
        case notEnrolled
        case differentFace
        case duplicate
    }

    /// Whether `embedding` may be added to `template`.
    public static func check(_ embedding: [Float], against template: FaceTemplate?) -> Refusal? {
        guard let template else { return .notEnrolled }
        guard FaceMath.cosineSimilarity(embedding, template.centroid) >= minimumSimilarityToLearn else {
            return .differentFace
        }
        // A frame almost identical to an existing sample adds nothing and only skews the average.
        if template.samples.contains(where: { FaceMath.cosineSimilarity(embedding, $0) > 0.995 }) {
            return .duplicate
        }
        return nil
    }

    /// Appends a learned sample, then trims learned samples (marked by `isLearned`) to the cap,
    /// oldest first. Guided samples are never trimmed.
    public static func appending<Sample>(
        _ sample: Sample,
        to samples: [Sample],
        isLearned: (Sample) -> Bool
    ) -> [Sample] {
        var result = samples + [sample]
        var learnedCount = result.filter(isLearned).count
        while learnedCount > maximumLearnedSamples, let index = result.firstIndex(where: isLearned) {
            result.remove(at: index)
            learnedCount -= 1
        }
        return result
    }
}
