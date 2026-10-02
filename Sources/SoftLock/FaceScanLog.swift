//
//  FaceScanLog.swift
//
//  Optional record of every face scan: a small photo of the face the camera saw, how the scan
//  ended, and the face signature it produced. Two uses: a security trail (who tried to unlock,
//  including strangers) and a way to improve face unlock — scans the owner approves are added
//  to the enrolled face (see FaceLearning).
//
//  Off by default. Each scan is one file, AES-GCM sealed under the same Keychain key as the face
//  profile, so the photos are unreadable without this Mac's login Keychain. Nothing leaves the
//  Mac. The newest `capacity` scans are kept.
//

import AppKit
import Foundation
import SoftLockCore

nonisolated enum FaceScanOutcome: String, Codable, Sendable {
    case unlocked
    case notRecognized
    case spoofSuspected
    case unconfirmed

    var title: String {
        switch self {
        case .unlocked: return "Unlocked"
        case .notRecognized: return "Not recognized"
        case .spoofSuspected: return "Looked like a photo or screen"
        case .unconfirmed: return "Could not confirm"
        }
    }
}

nonisolated struct FaceScanRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let outcome: FaceScanOutcome
    /// Best cosine similarity against the enrolled face (0.66 unlocks); nil when no face was judged.
    let score: Float?
    let jpeg: Data
    /// Signature of the face in `jpeg`, kept so an approval can learn from it without re-running
    /// the model. nil when no face was judged.
    let embedding: [Float]?
    var approvedAt: Date?
}

nonisolated enum FaceScanLog {
    static let capacity = 60
    private static let queue = DispatchQueue(label: "\(FaceUnlockPaths.appIdentifier).face-scan-log", qos: .utility)

    private static var directory: URL {
        FaceUnlockPaths.applicationSupportDirectory.appendingPathComponent("face-scans", isDirectory: true)
    }

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).scan")
    }

    /// Number of stored scans, without decrypting anything.
    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".scan") }.count ?? 0
    }

    /// Encodes the frame as a modest JPEG (640 px long edge is plenty for a thumbnail and a
    /// review) and writes it off the calling thread.
    static func record(frame: FaceCameraFrame, outcome: FaceScanOutcome, score: Float?, embedding: [Float]?) {
        queue.async {
            guard let jpeg = jpegData(from: frame.image) else { return }
            let record = FaceScanRecord(id: UUID(), date: Date(), outcome: outcome, score: score, jpeg: jpeg, embedding: embedding, approvedAt: nil)
            do {
                try write(record)
                trim()
            } catch {
                AppFaceLog.write("face scan log: could not save a scan: \(error.localizedDescription)")
            }
        }
    }

    /// Newest first. Files that cannot be opened (key removed, tampered) are skipped.
    static func load() -> [FaceScanRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let records: [FaceScanRecord] = names.compactMap { name in
            guard name.hasSuffix(".scan"),
                  let sealed = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let plain = try? FaceUnlockStore.openScan(sealed) else { return nil }
            return try? JSONDecoder().decode(FaceScanRecord.self, from: plain)
        }
        return records.sorted { $0.date > $1.date }
    }

    static func update(_ record: FaceScanRecord) {
        queue.sync { try? write(record) }
    }

    static func delete(_ id: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: url(for: id)) }
    }

    static func eraseAll() {
        queue.sync { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Private

    private static func write(_ record: FaceScanRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sealed = try FaceUnlockStore.sealScan(try JSONEncoder().encode(record))
        let target = url(for: record.id)
        try sealed.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Keeps the newest `capacity` files, judged by modification time so trimming never has to
    /// decrypt anything.
    private static func trim() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let files = urls.filter { $0.pathExtension == "scan" }
        guard files.count > capacity else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(capacity) { try? FileManager.default.removeItem(at: old) }
    }

    private static func jpegData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// Adds the scan's face to the enrolled face. Returns the refusal reason when the safety
    /// rules say no (not the same person as the enrolled face, a duplicate, nothing enrolled).
    @discardableResult
    static func learn(from record: FaceScanRecord) -> FaceLearning.Refusal? {
        guard let embedding = record.embedding else { return .differentFace }
        guard var profile = try? FaceUnlockStore.load(), let template = profile.template else { return .notEnrolled }
        if let refusal = FaceLearning.check(embedding, against: template) { return refusal }
        profile.samples = FaceLearning.appending(
            FaceSampleRecord(embedding: embedding, pose: FaceLearning.learnedPose),
            to: profile.samples,
            isLearned: { $0.pose == FaceLearning.learnedPose }
        )
        do {
            try FaceUnlockStore.save(profile)
        } catch {
            AppFaceLog.write("face scan log: could not save the learned sample: \(error.localizedDescription)")
            return .notEnrolled
        }
        var approved = record
        approved.approvedAt = Date()
        update(approved)
        return nil
    }
}
