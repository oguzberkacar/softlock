//
//  FaceScanReviewWindow.swift
//
//  Lists the stored face scans, newest first. "This is me" adds that scan's face to the
//  enrolled face (so face unlock learns from real, hard-angle frames); "Not me" deletes it.
//  Learning is refused for a face that does not resemble the enrolled one (see FaceLearning),
//  so a mis-click on a stranger cannot teach the model to accept them.
//

import AppKit
import SoftLockCore
import SwiftUI

@MainActor
private final class FaceScanReviewModel: ObservableObject {
    @Published var records: [FaceScanRecord] = []
    @Published var message: String?
    let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        reload()
    }

    func reload() {
        records = FaceScanLog.load()
    }

    func approve(_ record: FaceScanRecord) {
        if let refusal = FaceScanLog.learn(from: record) {
            switch refusal {
            case .differentFace: message = "That face does not look like your enrolled face, so it was not added."
            case .duplicate: message = "Face unlock already knows a frame just like this one."
            case .notEnrolled: message = "Set up your face first."
            }
        } else {
            message = "Added. Face unlock will use this scan from now on."
        }
        reload()
        onChange()
    }

    func reject(_ record: FaceScanRecord) {
        FaceScanLog.delete(record.id)
        reload()
        onChange()
    }

    func deleteAll() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete all stored scans?"
        alert.informativeText = "The photos are removed from this Mac. Faces you already approved stay in face unlock."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FaceScanLog.eraseAll()
        reload()
        onChange()
    }
}

private struct FaceScanReviewView: View {
    @ObservedObject var model: FaceScanReviewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.records.isEmpty {
                Text("No scans stored.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.records) { record in
                    ScanRow(record: record, approve: { model.approve(record) }, reject: { model.reject(record) })
                        .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text(model.message ?? "Mark the scans that are you. Face unlock learns from them; the rest can be deleted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Delete All…", role: .destructive) { model.deleteAll() }
                    .disabled(model.records.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct ScanRow: View {
    let record: FaceScanRecord
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = NSImage(data: record.jpeg) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.2)
                }
            }
            .frame(width: 96, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(record.outcome.title).font(.body.weight(.medium))
                }
                Text(record.date.formatted(date: .abbreviated, time: .standard))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let score = record.score {
                    Text("Similarity \(String(format: "%.2f", score)) · unlocks at \(String(format: "%.2f", FaceMatchPolicy.defaultThreshold))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if record.approvedAt != nil {
                Label("Learned", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Remove", action: reject)
            } else {
                if record.embedding != nil {
                    Button("This is me", action: approve)
                }
                Button("Not me", role: .destructive, action: reject)
            }
        }
    }

    private var color: Color {
        switch record.outcome {
        case .unlocked: return .green
        case .notRecognized: return .red
        case .spoofSuspected: return .orange
        case .unconfirmed: return .yellow
        }
    }
}

@MainActor
final class FaceScanReviewWindowController: NSObject, NSWindowDelegate {
    private static var current: FaceScanReviewWindowController?
    private let window: NSWindow

    static func present(onChange: @escaping () -> Void) {
        if let current {
            current.window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = FaceScanReviewWindowController(onChange: onChange)
        current = controller
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(onChange: @escaping () -> Void) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Face Scan History"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: FaceScanReviewView(model: FaceScanReviewModel(onChange: onChange)))
        window.setContentSize(NSSize(width: 600, height: 480))
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
