//
//  LockStatusViews.swift
//
//  Two small lock-screen widgets: the status pill (readable on any wallpaper) and the face
//  unlock self-view ring. Both have a fixed outer size so updating them never moves the centred
//  lock layout.
//

@preconcurrency import AVFoundation
import AppKit

/// Status text on a dark translucent pill with light text. Red / orange / green only appear as a
/// small dot, so the message stays legible over bright, busy or video backgrounds and in both
/// light and dark input appearance. The outer holder is a fixed 320 x 44 box; the pill inside
/// sizes to its text and is centred, so a message appearing or wrapping never shifts the layout.
@MainActor
final class LockStatusView: NSView {
    static let holderSize = CGSize(width: 320, height: 44)
    private static let horizontalPadding: CGFloat = 12
    private static let dotSize: CGFloat = 8
    private static let dotSpacing: CGFloat = 8

    private let pill = NSView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    var stringValue: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)

        pill.wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer?.cornerRadius = 16
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        // The blur always renders dark regardless of the app / input appearance.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.translatesAutoresizingMaskIntoConstraints = false
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.50).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(blur)
        pill.addSubview(tint)

        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = Self.dotSize / 2

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.96)
        label.alignment = .left
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        let textWidth = Self.holderSize.width - Self.horizontalPadding * 2 - Self.dotSize - Self.dotSpacing
        label.preferredMaxLayoutWidth = textWidth
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.addSubview(dot)
        pill.addSubview(label)
        addSubview(pill)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.holderSize.width),
            heightAnchor.constraint(equalToConstant: Self.holderSize.height),

            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pill.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),

            blur.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            blur.topAnchor.constraint(equalTo: pill.topAnchor),
            blur.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            tint.topAnchor.constraint(equalTo: pill.topAnchor),
            tint.bottomAnchor.constraint(equalTo: pill.bottomAnchor),

            dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: Self.horizontalPadding),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Self.dotSpacing),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth)
        ])
        pill.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, tone: FaceUnlockStatusKind = .error) {
        label.stringValue = text
        pill.isHidden = text.isEmpty
        guard !text.isEmpty else { return }
        dot.layer?.backgroundColor = Self.accent(for: tone).cgColor
        setAccessibilityLabel(text)
    }

    private static func accent(for tone: FaceUnlockStatusKind) -> NSColor {
        switch tone {
        case .info: return NSColor.white.withAlphaComponent(0.85)
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .error: return .systemRed
        }
    }
}

/// Low-key circular self-view for face unlock. The preview layer belongs to the same capture
/// session recognition uses (no second session) and only displays: nothing is recorded. Ring
/// colour: scanning white, recognized green, not recognized red. Fixed 64 x 64.
@MainActor
final class LockFaceSelfView: NSView {
    static let defaultDiameter: CGFloat = 64
    private static let ringWidth: CGFloat = 2
    private static let ringGap: CGFloat = 3

    private let diameter: CGFloat

    private let ring = CALayer()
    private let tint = CALayer()
    private let tick = CAShapeLayer()
    private let overlay = NSView()
    private var preview: FaceCameraPreviewView?
    private var state: FaceUnlockViewState = .scanning

    init(diameter: CGFloat = LockFaceSelfView.defaultDiameter) {
        self.diameter = diameter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(ring)
        overlay.wantsLayer = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        installOverlay()
        overlay.layer?.addSublayer(tint)
        overlay.layer?.addSublayer(tick)
        tint.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
        tint.opacity = 0
        tick.fillColor = nil
        tick.strokeColor = NSColor.white.cgColor
        tick.lineWidth = 4
        tick.lineCap = .round
        tick.lineJoin = .round
        tick.strokeEnd = 0
        ring.borderWidth = Self.ringWidth
        ring.cornerRadius = diameter / 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter)
        ])
        setAccessibilityElement(false)
        applyState()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Attaches after the session is running so the preview connection exists when the mirroring
    /// is set up.
    func attachPreview(session: AVCaptureSession) {
        guard preview == nil else { isHidden = false; return }
        let view = FaceCameraPreviewView(session: session)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let inset = Self.ringWidth + Self.ringGap
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
        preview = view
        installOverlay()
        isHidden = false
    }

    /// (Re)adds the tint/tick overlay above the preview, which is a sibling view and would otherwise cover the layers.
    private func installOverlay() {
        overlay.removeFromSuperview()
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func detach() {
        preview?.removeFromSuperview()
        preview = nil
        isHidden = true
        // Back to neutral: a green ring and tick left over from a successful scan must not be
        // what the next scan (or the next lock screen) starts from.
        setState(.scanning)
    }

    func setState(_ newState: FaceUnlockViewState) {
        state = newState
        applyState()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        let inset = Self.ringWidth + Self.ringGap
        tint.frame = bounds.insetBy(dx: inset, dy: inset)
        tint.cornerRadius = tint.frame.width / 2
        tick.frame = bounds
        let w = bounds.width, h = bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: w * 0.29, y: h * 0.50))
        path.addLine(to: CGPoint(x: w * 0.44, y: h * 0.35))
        path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.66))
        tick.path = path
        CATransaction.commit()
    }

    private func applyState() {
        let color: NSColor
        switch state {
        case .scanning: color = NSColor.white.withAlphaComponent(0.55)
        case .recognized: color = NSColor.systemGreen.withAlphaComponent(0.9)
        case .notRecognized: color = NSColor.systemRed.withAlphaComponent(0.9)
        }
        ring.borderColor = color.cgColor
        let recognized = state == .recognized
        tint.opacity = recognized ? 1 : 0
        if recognized {
            if tick.strokeEnd < 1 {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = 0.28
                draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
                tick.strokeEnd = 1
                tick.add(draw, forKey: "draw")
            }
        } else {
            tick.removeAllAnimations()
            tick.strokeEnd = 0
        }
    }
}
