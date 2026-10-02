//
//  TouchMouse.swift
//  Starlight
//
//  Turns touches into mouse input, for hosts or apps that don't take
//  multi-touch. As a trackpad, one finger moves the cursor, a tap clicks and
//  a double tap held down drags. With direct tap, the cursor goes where the
//  finger lands, which clicks or drags there and right clicks on a long
//  press. Either way, two fingers scroll, a two finger tap right clicks and
//  a three finger tap middle clicks.
//

#if os(iOS)
import MoonlightBridge
import UIKit

final class TouchMouse {
    /// Either mode other than multi-touch.
    var mode: TouchMode

    private let input: StreamInput

    /// Fingers on the screen, in the order they came down.
    private var touches: [UITouch] = []
    /// The most fingers down at once since the first one came down.
    private var maxFingers = 0
    private var startLocation = CGPoint.zero
    private var startTime: TimeInterval = 0
    /// The fingers went farther than a tap allows.
    private var moved = false
    /// A long press already acted, so lifting the finger does nothing more.
    private var consumed = false
    /// The left button is held for a drag.
    private var dragging = false
    /// Where the last finger was, to measure motion from.
    private var lastLocation = CGPoint.zero
    private var lastTap: (location: CGPoint, time: TimeInterval)?
    private var longPress: Task<Void, Never>?

    /// Points a finger can move and still tap.
    private static let tapSlop: CGFloat = 10
    /// How long a trackpad tap can last.
    private static let tapDuration: TimeInterval = 0.3
    /// How soon after a tap another one can start a drag or double click.
    private static let doubleTapInterval: TimeInterval = 0.3
    /// How far apart the taps of a double tap can be.
    private static let doubleTapDistance: CGFloat = 40
    private static let longPressDuration: Duration = .milliseconds(500)
    /// Host pixels per pixel of finger motion as a trackpad.
    private static let trackpadSpeed = 1.5

    init(mode: TouchMode, input: StreamInput) {
        self.mode = mode
        self.input = input
    }

    func touchesBegan(_ began: [UITouch], in view: UIView) {
        let wasEmpty = touches.isEmpty
        touches += began
        maxFingers = max(maxFingers, touches.count)

        guard wasEmpty, touches.count == 1, let touch = touches.first else {
            // More fingers end a single finger gesture
            cancelLongPress()
            endDrag()
            lastLocation = centroid(in: view)
            return
        }

        let location = touch.location(in: view)
        let isDoubleTap = lastTap.map {
            touch.timestamp - $0.time < Self.doubleTapInterval
                && distance($0.location, location) < Self.doubleTapDistance
        } ?? false
        startLocation = location
        startTime = touch.timestamp
        lastLocation = location
        moved = false
        consumed = false

        switch mode {
        case .trackpad:
            // The second tap of a double tap holds the button, so moving
            // drags and lifting finishes a double click
            if isDoubleTap {
                input.setMouseButton(.left, pressed: true)
                dragging = true
                lastTap = nil
            }
        case .directTap:
            // Leaving the cursor put makes a double click land on the same spot
            if !isDoubleTap {
                input.moveMouse(to: location, in: view.bounds)
            }
            longPress = Task { [weak self] in
                try? await Task.sleep(for: Self.longPressDuration)
                guard !Task.isCancelled, let self, !self.moved, self.touches.count == 1 else { return }
                self.consumed = true
                self.click(.right)
            }
        case .multiTouch:
            break
        }
    }

    func touchesMoved(in view: UIView) {
        guard !touches.isEmpty, !consumed else { return }

        if touches.count == 1 {
            // A finger left over from a multi-finger gesture
            guard maxFingers == 1, let touch = touches.first else { return }
            let location = touch.location(in: view)
            if !moved {
                guard distance(location, startLocation) > Self.tapSlop else { return }
                moved = true
                cancelLongPress()
                // Start from here, so the slop doesn't make the cursor jump
                lastLocation = location
                if mode == .directTap {
                    input.setMouseButton(.left, pressed: true)
                    dragging = true
                }
            }

            switch mode {
            case .trackpad:
                let scale = pixelsPerPoint(in: view.bounds) * Self.trackpadSpeed
                input.moveMouse(dx: (location.x - lastLocation.x) * scale, dy: (location.y - lastLocation.y) * scale)
            case .directTap:
                input.moveMouse(to: location, in: view.bounds)
            case .multiTouch:
                break
            }
            lastLocation = location
        } else {
            let location = centroid(in: view)
            if !moved {
                guard distance(location, lastLocation) > Self.tapSlop else { return }
                moved = true
                lastLocation = location
            }
            // Same as scrolling on a trackpad, see StreamSurfaceView
            guard view.bounds.height > 0 else { return }
            let notchesPerPoint = 20 / view.bounds.height
            input.scroll(
                vertical: (location.y - lastLocation.y) * notchesPerPoint,
                horizontal: -(location.x - lastLocation.x) * notchesPerPoint
            )
            lastLocation = location
        }
    }

    func touchesEnded(_ ended: [UITouch], cancelled: Bool, in view: UIView) {
        // Ones that came down in another mode aren't followed
        let ended = ended.filter { touches.contains($0) }
        guard !ended.isEmpty else { return }
        let endTime = ended.map(\.timestamp).max() ?? startTime
        touches.removeAll { ended.contains($0) }
        guard touches.isEmpty else {
            // Keep a scroll going from where the other fingers are
            lastLocation = centroid(in: view)
            return
        }
        cancelLongPress()

        let isTap = !cancelled && !moved && !consumed
            && ((mode == .directTap && maxFingers == 1) || endTime - startTime < Self.tapDuration)
        if dragging {
            endDrag()
        } else if isTap {
            switch maxFingers {
            case 1:
                click(.left)
                lastTap = (startLocation, endTime)
            case 2:
                click(.right)
            case 3:
                click(.middle)
            default:
                break
            }
        }
        if !isTap || maxFingers > 1 {
            lastTap = nil
        }
        maxFingers = 0
    }

    /// Forgets the fingers and lets go of the buttons, e.g. when touches stop
    /// coming in.
    func reset() {
        cancelLongPress()
        endDrag()
        touches.removeAll()
        maxFingers = 0
        lastTap = nil
    }

    // MARK: - Helpers

    private func click(_ button: SLMouseButton) {
        input.setMouseButton(button, pressed: true)
        // Held briefly, since games may check the button only once a frame
        Task { [input] in
            try? await Task.sleep(for: .milliseconds(50))
            input.setMouseButton(button, pressed: false)
        }
    }

    private func endDrag() {
        guard dragging else { return }
        dragging = false
        input.setMouseButton(.left, pressed: false)
    }

    private func cancelLongPress() {
        longPress?.cancel()
        longPress = nil
    }

    private func centroid(in view: UIView) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        let sum = touches.reduce(CGPoint.zero) {
            let location = $1.location(in: view)
            return CGPoint(x: $0.x + location.x, y: $0.y + location.y)
        }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }

    /// Host pixels per point of the video as shown, so a swipe across the
    /// video crosses the host's screen at speed 1.
    private func pixelsPerPoint(in bounds: CGRect) -> Double {
        let rect = input.videoRect(in: bounds)
        guard let videoSize = input.videoSize, rect.width > 0 else { return 1 }
        return videoSize.width / rect.width
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
#endif
