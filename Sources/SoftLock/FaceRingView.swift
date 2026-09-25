//
//  FaceRingView.swift
//
//  The enrollment / test "face ring": a circular, mirrored live camera preview surrounded by 80
//  tick marks. Each 45 degree sector fills when its head direction has been captured, the current
//  target sector pulses with an arrow pointing at it, and a short band of ticks follows where the
//  head is actually turned. Ring layout follows jonnyoo/glance's EnrollmentRingView (MIT), see
//  THIRD_PARTY_NOTICES.md; this version is AppKit + Core Animation.
//
//  The view is a fixed square (intrinsic size, so Auto Layout never has to guess). Tick geometry
//  is derived from `bounds` inside `layout()` only, so it cannot drift from the view's size.
//

@preconcurrency import AVFoundation
import AppKit
import SoftLockCore

/// Hosts an `AVCaptureVideoPreviewLayer`, circular and mirrored like a mirror, tracking the view's bounds.
final class FaceCameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        // Frames handed to Vision are never mirrored, so the mirror is applied here, on the
        // layer, and the automatic connection mirroring is pinned off to make it deterministic.
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        previewLayer.frame = bounds
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        CATransaction.commit()
    }
}

@MainActor
final class FaceRingView: NSView {
    static let side: CGFloat = 340
    static let previewDiameter: CGFloat = 224

    private static let tickCount = 80
    private static let ticksPerSector = 10
    private static let tickInnerRadius: CGFloat = 124
    private static let tickWidth: CGFloat = 2.6
    private static let idleLength: CGFloat = 14
    private static let targetLength: CGFloat = 18
    private static let litLength: CGFloat = 22
    private static let arrowRadius: CGFloat = 156
    private static let borderRadius: CGFloat = 116

    private enum TickKind: Equatable {
        case idle
        case turn(Int)   // quantised head-turn intensity, 1...4
        case target
        case lit
    }

    private let ringLayer = CALayer()
    private let tickGroup = CALayer()
    private let borderLayer = CAShapeLayer()
    private let arrowContainer = CALayer()
    private let arrowLayer = CAShapeLayer()
    private var tickContainers: [CALayer] = []
    private var tickBars: [CALayer] = []
    private var tickKinds: [TickKind] = []
    private var errorFlashing = false

    private var capturedSectors: Set<Int> = []
    private var targetSector: Int?
    private var targetPose: EnrollmentPose?
    private var headTurn: EnrollmentHeadTurn?
    private var isComplete = false

    private let previewSlot = NSView()
    private let overlay = FaceRingOverlayView()
    private var previewView: FaceCameraPreviewView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildLayers()
        buildSubviews()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Camera preview with head direction progress ring")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    // MARK: - Build

    private func buildLayers() {
        layer?.addSublayer(ringLayer)
        ringLayer.addSublayer(borderLayer)
        ringLayer.addSublayer(tickGroup)
        ringLayer.addSublayer(arrowContainer)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 3

        for _ in 0..<Self.tickCount {
            let container = CALayer()
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = Self.tickWidth / 2
            container.addSublayer(bar)
            tickGroup.addSublayer(container)
            tickContainers.append(container)
            tickBars.append(bar)
            tickKinds.append(.idle)
        }

        arrowLayer.fillColor = nil
        arrowLayer.lineWidth = 3.5
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: -7, y: -3.5))
        chevron.addLine(to: CGPoint(x: 0, y: 3.5))
        chevron.addLine(to: CGPoint(x: 7, y: -3.5))
        arrowLayer.path = chevron
        arrowLayer.bounds = CGRect(x: -10, y: -10, width: 20, height: 20)
        arrowContainer.addSublayer(arrowLayer)
        arrowContainer.isHidden = true
    }

    private func buildSubviews() {
        previewSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewSlot)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            previewSlot.centerXAnchor.constraint(equalTo: centerXAnchor),
            previewSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewSlot.widthAnchor.constraint(equalToConstant: Self.previewDiameter),
            previewSlot.heightAnchor.constraint(equalToConstant: Self.previewDiameter),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Adds the live preview once the capture session exists.
    func attachPreview(session: AVCaptureSession) {
        guard previewView == nil else { return }
        let view = FaceCameraPreviewView(session: session)
        view.translatesAutoresizingMaskIntoConstraints = false
        previewSlot.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: previewSlot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: previewSlot.trailingAnchor),
            view.topAnchor.constraint(equalTo: previewSlot.topAnchor),
            view.bottomAnchor.constraint(equalTo: previewSlot.bottomAnchor),
        ])
        previewView = view
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        ringLayer.bounds = bounds
        ringLayer.position = center
        tickGroup.bounds = bounds
        tickGroup.position = center

        borderLayer.bounds = bounds
        borderLayer.position = center
        borderLayer.path = CGPath(
            ellipseIn: CGRect(x: center.x - Self.borderRadius, y: center.y - Self.borderRadius,
                              width: Self.borderRadius * 2, height: Self.borderRadius * 2),
            transform: nil
        )

        for index in 0..<Self.tickCount {
            let container = tickContainers[index]
            container.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
            container.position = center
            // Compass angles run clockwise; Core Animation rotations are counter-clockwise.
            let angle = -CGFloat(index) * 2 * .pi / CGFloat(Self.tickCount)
            container.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            let bar = tickBars[index]
            bar.position = CGPoint(x: 0.5, y: 0.5 + Self.tickInnerRadius)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.tickWidth, height: bar.bounds.height > 0 ? bar.bounds.height : Self.idleLength)
        }

        arrowContainer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        arrowContainer.position = center
        arrowLayer.position = CGPoint(x: 0.5, y: 0.5 + Self.arrowRadius)
        updateArrowRotation()
        CATransaction.commit()
        restyleAll(animated: false, force: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleAll(animated: false, force: true)
    }

    // MARK: - Public state

    func setTarget(_ pose: EnrollmentPose?) {
        targetPose = pose
        if let angle = pose?.compassAngle {
            targetSector = EnrollmentPose.sector(forAngle: angle)
        } else {
            targetSector = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrowContainer.isHidden = pose?.compassAngle == nil
        updateArrowRotation()
        CATransaction.commit()
        updateArrowAnimation()
        updateCenterPulse()
        restyleAll(animated: true, force: false)
    }

    func setCaptured(_ poses: Set<EnrollmentPose>) {
        let sectors = Set(poses.compactMap { $0.compassAngle }.map { EnrollmentPose.sector(forAngle: $0) })
        guard sectors != capturedSectors else { return }
        capturedSectors = sectors
        restyleAll(animated: true, force: false)
    }

    func setHeadTurn(_ turn: EnrollmentHeadTurn?) {
        guard headTurn != turn else { return }
        headTurn = turn
        restyleAll(animated: false, force: false)
    }

    /// A direction was captured: green pop, checkmark badge and a haptic tick.
    func pulseCapture(sectorFilled: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        flashBorder(.systemGreen)
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.035, 1.0]
        pop.keyTimes = [0, 0.4, 1]
        pop.duration = 0.35
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ringLayer.add(pop, forKey: "pop")
        if sectorFilled { overlay.playCaptureBadge() }
    }

    /// A frame was rejected: the ring and border flash a gentle red.
    func flashError() {
        flashBorder(.systemRed)
        guard !errorFlashing else { return }
        errorFlashing = true
        withAppearance {
            let red = NSColor.systemRed.cgColor
            for (index, bar) in tickBars.enumerated() where tickKinds[index] != .lit {
                let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
                animation.values = [bar.backgroundColor ?? red, red, bar.backgroundColor ?? red]
                animation.keyTimes = [0, 0.3, 1]
                animation.duration = 0.7
                bar.add(animation, forKey: "errorFlash")
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            self?.errorFlashing = false
        }
    }

    /// All directions captured: every tick turns green and a big checkmark draws itself.
    func showComplete() {
        isComplete = true
        capturedSectors = Set(0..<8)
        targetSector = nil
        targetPose = nil
        arrowContainer.isHidden = true
        updateArrowAnimation()
        updateCenterPulse()
        restyleAll(animated: true, force: true)
        setBorderColor(.systemGreen)
        previewView?.animator().alphaValue = 0.2
        overlay.showBigCheckmark()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// Setup failed: dim the preview and turn the border red; the caller explains and offers retry.
    func showFailure() {
        setBorderColor(.systemRed)
        previewView?.animator().alphaValue = 0.35
        arrowContainer.isHidden = true
        updateArrowAnimation()
        updateCenterPulse()
    }

    /// Back to a fresh, empty ring.
    func resetProgress() {
        isComplete = false
        capturedSectors = []
        headTurn = nil
        previewView?.alphaValue = 1
        overlay.hideBigCheckmark()
        setBorderColor(nil)
        restyleAll(animated: false, force: true)
    }

    // MARK: - Styling

    private func withAppearance(_ body: () -> Void) {
        effectiveAppearance.performAsCurrentDrawingAppearance(body)
    }

    private func setBorderColor(_ color: NSColor?) {
        withAppearance {
            borderLayer.strokeColor = (color ?? NSColor.tertiaryLabelColor).cgColor
        }
    }

    private func flashBorder(_ color: NSColor) {
        withAppearance {
            let flash = CAKeyframeAnimation(keyPath: "strokeColor")
            let base = borderLayer.strokeColor ?? NSColor.tertiaryLabelColor.cgColor
            flash.values = [base, color.cgColor, base]
            flash.keyTimes = [0, 0.25, 1]
            flash.duration = 0.7
            borderLayer.add(flash, forKey: "flash")
        }
    }

    private func kind(forTick index: Int) -> TickKind {
        let angle = Double(index) * 360.0 / Double(Self.tickCount)
        let sector = EnrollmentPose.sector(forAngle: angle)
        if capturedSectors.contains(sector) || isComplete { return .lit }
        if targetSector == sector { return .target }
        if let headTurn {
            var delta = abs(angle - headTurn.angle)
            if delta > 180 { delta = 360 - delta }
            let degreesPerTick = 360.0 / Double(Self.tickCount)
            let falloff = max(0, 1 - (delta / degreesPerTick) / 4)
            let intensity = headTurn.progress * falloff
            let level = Int((intensity * 4).rounded())
            if level > 0 { return .turn(level) }
        }
        return .idle
    }

    private func restyleAll(animated: Bool, force: Bool) {
        withAppearance {
            if borderLayer.strokeColor == nil { borderLayer.strokeColor = NSColor.tertiaryLabelColor.cgColor }
            for index in 0..<Self.tickCount {
                let newKind = kind(forTick: index)
                guard force || newKind != tickKinds[index] else { continue }
                let wasLit = tickKinds[index] == .lit
                tickKinds[index] = newKind
                style(bar: tickBars[index], kind: newKind, index: index, animated: animated, stagger: newKind == .lit && !wasLit)
            }
        }
    }

    private func style(bar: CALayer, kind: TickKind, index: Int, animated: Bool, stagger: Bool) {
        let length: CGFloat
        let color: NSColor
        switch kind {
        case .idle:
            length = Self.idleLength
            color = .tertiaryLabelColor
        case .turn(let level):
            length = Self.idleLength + CGFloat(level) * 1.5
            color = NSColor.controlAccentColor.withAlphaComponent(0.35 + 0.16 * CGFloat(level))
        case .target:
            length = Self.targetLength
            color = .controlAccentColor
        case .lit:
            length = Self.litLength
            color = .systemGreen
        }
        let newBounds = CGRect(x: 0, y: 0, width: Self.tickWidth, height: length)
        let newColor = color.cgColor
        let oldBounds = bar.presentation()?.bounds ?? bar.bounds
        let oldColor = bar.presentation()?.backgroundColor ?? bar.backgroundColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = newBounds
        bar.backgroundColor = newColor
        CATransaction.commit()

        bar.removeAnimation(forKey: "pulse")
        if kind == .target {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(pulse, forKey: "pulse")
        }

        guard animated else { return }
        let delay = stagger ? Double(index % Self.ticksPerSector) * 0.02 : 0
        let grow = CABasicAnimation(keyPath: "bounds")
        grow.fromValue = oldBounds
        grow.toValue = newBounds
        let tint = CABasicAnimation(keyPath: "backgroundColor")
        tint.fromValue = oldColor
        tint.toValue = newColor
        for animation in [grow, tint] {
            animation.duration = 0.25
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        bar.add(grow, forKey: "grow")
        bar.add(tint, forKey: "tint")
    }

    // MARK: - Arrow and center pulse

    private func updateArrowRotation() {
        guard let angle = targetPose?.compassAngle else { return }
        arrowContainer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(angle) * .pi / 180))
        withAppearance { arrowLayer.strokeColor = NSColor.controlAccentColor.cgColor }
    }

    private func updateArrowAnimation() {
        arrowLayer.removeAnimation(forKey: "nudge")
        guard !arrowContainer.isHidden else { return }
        let nudge = CABasicAnimation(keyPath: "position.y")
        nudge.fromValue = 0.5 + Self.arrowRadius - 3
        nudge.toValue = 0.5 + Self.arrowRadius + 5
        nudge.duration = 0.55
        nudge.autoreverses = true
        nudge.repeatCount = .infinity
        nudge.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrowLayer.add(nudge, forKey: "nudge")
    }

    /// Center has no sector, so while it is the target the whole tick ring breathes instead.
    private func updateCenterPulse() {
        tickGroup.removeAnimation(forKey: "breathe")
        guard targetPose == .center else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0
        breathe.toValue = 0.4
        breathe.duration = 0.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tickGroup.add(breathe, forKey: "breathe")
    }
}

// MARK: - Overlay (checkmarks above the preview)

private func checkmarkPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.48))
    path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.22))
    path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.78))
    return path
}

/// Sits above the preview: a brief per-capture badge and the large completion checkmark.
@MainActor
final class FaceRingOverlayView: NSView {
    private let badge = CAShapeLayer()
    private let badgeCheck = CAShapeLayer()
    private let bigCheck = CAShapeLayer()
    private let bigDisc = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for layer in [badge, badgeCheck, bigCheck, bigDisc] { layer.actions = ["opacity": NSNull()] }
        badge.opacity = 0
        badgeCheck.fillColor = nil
        badgeCheck.strokeColor = NSColor.white.cgColor
        badgeCheck.lineWidth = 5
        badgeCheck.lineCap = .round
        badgeCheck.lineJoin = .round
        badge.addSublayer(badgeCheck)
        bigCheck.fillColor = nil
        bigCheck.lineWidth = 10
        bigCheck.lineCap = .round
        bigCheck.lineJoin = .round
        bigCheck.strokeEnd = 0
        bigDisc.opacity = 0
        layer?.addSublayer(bigDisc)
        layer?.addSublayer(bigCheck)
        layer?.addSublayer(badge)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        let badgeSize: CGFloat = 72
        badge.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
        badge.position = center
        badge.path = CGPath(ellipseIn: badge.bounds, transform: nil)
        badgeCheck.frame = badge.bounds
        badgeCheck.path = checkmarkPath(in: badge.bounds.insetBy(dx: 14, dy: 14))

        let bigSize: CGFloat = 132
        let bigRect = CGRect(x: 0, y: 0, width: bigSize, height: bigSize)
        bigDisc.bounds = bigRect
        bigDisc.position = center
        bigDisc.path = CGPath(ellipseIn: bigRect, transform: nil)
        bigCheck.bounds = bigRect
        bigCheck.position = center
        bigCheck.path = checkmarkPath(in: bigRect.insetBy(dx: 30, dy: 30))
        CATransaction.commit()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            badge.fillColor = NSColor.systemGreen.cgColor
            bigDisc.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
            bigCheck.strokeColor = NSColor.systemGreen.cgColor
        }
    }

    func playCaptureBadge() {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.2, 0.65, 1]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.6, 1.08, 1.0, 1.0]
        scale.keyTimes = [0, 0.3, 0.5, 1]
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = 0.75
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        badge.add(group, forKey: "badge")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.25
        badgeCheck.add(draw, forKey: "draw")
    }

    func showBigCheckmark() {
        bigDisc.opacity = 1
        bigCheck.strokeEnd = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3
        bigDisc.add(fade, forKey: "fade")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.45
        draw.beginTime = CACurrentMediaTime() + 0.2
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        bigCheck.add(draw, forKey: "draw")
    }

    func hideBigCheckmark() {
        bigDisc.opacity = 0
        bigCheck.strokeEnd = 0
    }
}
