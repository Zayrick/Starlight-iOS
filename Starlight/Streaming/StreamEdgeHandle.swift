//
//  StreamEdgeHandle.swift
//  Starlight
//
//  A faint accent near the top of the left or right edge that follows the
//  screen's corner. Pulling it away from the edge drives the stream drawer,
//  which follows the finger. Touches starting on it are kept from the host;
//  all others pass through to the stream.
//

#if os(iOS)
import SwiftUI
import UIKit

struct StreamEdgeHandle: UIViewRepresentable {
    /// The screen edge it sits on, the left one for leading.
    var edge: HorizontalEdge = .leading
    var isDashed = false
    /// Whether the accent itself moves a short way after a pull.
    var followsPull = false
    /// What VoiceOver reads out, when there's something to activate.
    var title = "串流选项"
    /// How far the handle is pulled away from its edge, as the finger moves.
    var onPull: ((CGFloat) -> Void)?
    /// How far the handle was pulled when let go, and how fast the finger
    /// was moving away from its edge, in points per second.
    var onRelease: ((_ distance: CGFloat, _ velocity: CGFloat) -> Void)?
    /// Opens the drawer without a pull, e.g. from VoiceOver.
    var onActivate: (() -> Void)?

    func makeUIView(context: Context) -> StreamEdgeHandleView {
        StreamEdgeHandleView(edge: edge)
    }

    func updateUIView(_ view: StreamEdgeHandleView, context: Context) {
        view.isDashed = isDashed
        view.followsPull = followsPull
        // Without anything to open, there's nothing to offer VoiceOver
        view.isAccessibilityElement = onActivate != nil
        view.accessibilityLabel = title
        view.onPull = onPull
        view.onRelease = onRelease
        view.onActivate = onActivate
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
    /// The furthest the accent follows a pull, which it eases toward.
    private static let maxPullOffset: CGFloat = 8

    var onPull: ((CGFloat) -> Void)?
    var onRelease: ((CGFloat, CGFloat) -> Void)?
    var onActivate: (() -> Void)?
    var followsPull = false

    var isDashed = false {
        didSet {
            // Short dashes, which the round caps lengthen by a line width
            accentLayer.lineDashPattern = isDashed ? [4, 7] : nil
        }
    }

    private let edge: HorizontalEdge
    /// Fades and follows a pull on its own while this view stays put to
    /// measure the corner.
    private let accentView = UIView()
    private let accentLayer = CAShapeLayer()
    private var hitRect = CGRect.null
    private var fadeTask: Task<Void, Never>?

    init(edge: HorizontalEdge) {
        self.edge = edge
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

        accessibilityTraits = .button

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

    override var accessibilityFrame: CGRect {
        get { hitRect.isNull ? .zero : UIAccessibility.convertToScreenCoordinates(hitRect, in: self) }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Unlike the frame, these leave a pull's transform in place
        accentView.bounds = bounds
        accentView.center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Reading the radius during layout also follows its changes
        let corner: UIRectCorner = edge == .leading ? .topLeft : .topRight
        let path = window == nil ? nil : accentPath(cornerRadius: effectiveRadius(corner: corner))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accentLayer.frame = accentView.bounds
        accentLayer.contentsScale = traitCollection.displayScale
        accentLayer.path = path?.cgPath
        CATransaction.commit()

        if let path {
            let accentBounds = path.bounds.insetBy(dx: -Self.lineWidth / 2, dy: -Self.lineWidth / 2)
            let minX = edge == .leading ? 0 : bounds.maxX - Self.hitWidth
            hitRect = CGRect(x: minX, y: 0, width: Self.hitWidth, height: accentBounds.maxY + Self.hitPadding)
        } else {
            hitRect = .null
        }
    }

    /// The stroke's center line along its edge, bending with the top
    /// corner, or straight without one.
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
        // Drawn for the left edge, then mirrored onto the right one
        if edge == .trailing {
            path.apply(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0))
        }
        return path
    }

    // MARK: - Pulling

    @objc private func handlePull(_ recognizer: UIPanGestureRecognizer) {
        // Away from the edge counts as positive on either side
        let direction: CGFloat = edge == .leading ? 1 : -1
        let distance = max(recognizer.translation(in: self).x * direction, 0)
        switch recognizer.state {
        case .began, .changed:
            highlight()
            if followsPull {
                follow(distance * direction)
            }
            onPull?(distance)
        case .ended:
            onRelease?(distance, recognizer.velocity(in: self).x * direction)
            release()
        default:
            // A cancelled pull puts the drawer back
            onRelease?(0, 0)
            release()
        }
    }

    /// Moves the accent a short way after the finger, rubber-banding toward
    /// maxPullOffset.
    private func follow(_ pull: CGFloat) {
        let offset = Self.maxPullOffset * (1 - exp(-abs(pull) / Self.maxPullOffset))
        accentView.transform = CGAffineTransform(translationX: pull < 0 ? -offset : offset, y: 0)
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
        if accentView.transform != .identity {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.accentView.transform = .identity
            }
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
