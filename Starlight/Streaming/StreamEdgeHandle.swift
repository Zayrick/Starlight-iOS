//
//  StreamEdgeHandle.swift
//  Starlight
//
//  A faint accent near the top of the left edge that follows the screen's
//  corner. Pulling it right and letting go opens a menu with the system's
//  own animation. Touches starting on it are kept from the host; all others
//  pass through to the stream.
//

#if os(iOS)
import SwiftUI
import UIKit

struct StreamEdgeHandle: UIViewRepresentable {
    let menu: UIMenu

    func makeUIView(context: Context) -> StreamEdgeHandleView {
        StreamEdgeHandleView()
    }

    func updateUIView(_ view: StreamEdgeHandleView, context: Context) {
        view.menu = menu
    }
}

final class StreamEdgeHandleView: UIView {
    private static let lineWidth: CGFloat = 3
    /// The accent's extent including its round caps, from the top.
    private static let accentTop: CGFloat = 15
    private static let accentHeight: CGFloat = 70.5
    /// The touch target reaches past the few points the accent covers.
    private static let hitWidth: CGFloat = 32
    private static let hitPadding: CGFloat = 12
    private static let idleAlpha: CGFloat = 0.2
    private static let activeAlpha: CGFloat = 0.8
    /// How far the accent follows the finger, however far it's pulled.
    private static let maxPullOffset: CGFloat = 8
    /// How far the finger has to pull for letting go to open the menu.
    private static let openDistance: CGFloat = 32

    var menu: UIMenu? {
        get { menuButton.menu }
        set { menuButton.menu = newValue }
    }

    /// Moves with the pull while this view stays put to measure the corner.
    private let accentView = UIView()
    private let accentLayer = CAShapeLayer()
    /// Never touched directly, it presents the menu next to the accent.
    private let menuButton = UIButton(type: .system)
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private var hitRect = CGRect.null
    /// Whether letting go now opens the menu.
    private var isArmed = false
    private var fadeTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        // Bends the accent to match the screen's corner
        cornerConfiguration = .corners(radius: .containerConcentric())

        accentView.isUserInteractionEnabled = false
        accentView.alpha = Self.idleAlpha
        addSubview(accentView)

        accentLayer.fillColor = nil
        accentLayer.strokeColor = UIColor.white.cgColor
        accentLayer.lineWidth = Self.lineWidth
        accentLayer.lineCap = .round
        accentView.layer.addSublayer(accentLayer)

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = "串流选项"
        addSubview(menuButton)

        let pull = UIPanGestureRecognizer(target: self, action: #selector(handlePull))
        pull.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        addGestureRecognizer(pull)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        hitRect.contains(point) ? self : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Setting bounds and center leaves an ongoing pull's transform alone
        accentView.bounds = bounds
        accentView.center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Reading the radius during layout also follows its changes
        let path = window == nil ? nil : accentPath(cornerRadius: effectiveRadius(corner: .topLeft))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accentLayer.frame = accentView.bounds
        accentLayer.contentsScale = traitCollection.displayScale
        accentLayer.path = path?.cgPath
        CATransaction.commit()

        if let path {
            let accentBounds = path.bounds.insetBy(dx: -Self.lineWidth / 2, dy: -Self.lineWidth / 2)
            menuButton.frame = accentBounds
            hitRect = CGRect(x: 0, y: 0, width: Self.hitWidth, height: accentBounds.maxY + Self.hitPadding)
        } else {
            menuButton.frame = .zero
            hitRect = .null
        }
    }

    /// The stroke's center line along the left edge, bending with the
    /// top-left corner, or straight without one.
    private func accentPath(cornerRadius: CGFloat) -> UIBezierPath? {
        // Inset by half the line so the stroke hugs the edge like a border,
        // and leave room for the round caps past each end
        let inset = Self.lineWidth / 2
        let minY = Self.accentTop + inset
        let maxY = min(Self.accentTop + Self.accentHeight - inset, bounds.midY)
        guard maxY > minY else { return nil }

        let radius = cornerRadius.isFinite ? max(cornerRadius - inset, 0) : 0
        let center = CGPoint(x: inset + radius, y: inset + radius)
        // The angle of the corner's left side at height y
        func angle(atY y: CGFloat) -> CGFloat {
            .pi - asin((y - center.y) / radius)
        }

        let path = UIBezierPath()
        if minY < center.y {
            path.addArc(withCenter: center, radius: radius,
                        startAngle: angle(atY: minY), endAngle: angle(atY: min(maxY, center.y)),
                        clockwise: false)
        } else {
            path.move(to: CGPoint(x: inset, y: minY))
        }
        if maxY > center.y {
            path.addLine(to: CGPoint(x: inset, y: maxY))
        }
        return path
    }

    // MARK: - Pulling

    @objc private func handlePull(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            if recognizer.state == .began {
                // Pick up from wherever the last release left off
                accentView.layer.removeAllAnimations()
                feedback.prepare()
            }
            let pull = max(recognizer.translation(in: self).x, 0)
            // Pulling back far enough before letting go keeps the menu closed
            let isArmed = pull >= Self.openDistance
            if isArmed, !self.isArmed {
                feedback.impactOccurred()
            }
            self.isArmed = isArmed
            highlight()
            // Rubber-band toward maxPullOffset
            let offset = Self.maxPullOffset * (1 - exp(-pull / Self.maxPullOffset))
            accentView.transform = CGAffineTransform(translationX: offset, y: 0)
        case .ended:
            if isArmed {
                menuButton.performPrimaryAction()
            }
            release()
        default:
            release()
        }
    }

    private func highlight() {
        fadeTask?.cancel()
        fadeTask = nil
        guard accentView.alpha != Self.activeAlpha else { return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.accentView.alpha = Self.activeAlpha
        }
    }

    private func release() {
        isArmed = false
        UIView.animate(springDuration: 0.45, bounce: 0.35, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.accentView.transform = .identity
        }
        guard accentView.alpha != Self.idleAlpha else { return }
        // Stays lit for a moment so it's easy to find again
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.accentView.alpha = Self.idleAlpha
            }
        }
    }
}
#endif
