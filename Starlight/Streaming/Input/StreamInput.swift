//
//  StreamInput.swift
//  Starlight
//
//  Sends keyboard, mouse and touch input to the host. It remembers what's
//  held down, so everything can be released when the stream loses focus or
//  stops, instead of getting stuck on the host.
//

import AVFoundation
import MoonlightBridge

final class StreamInput {
    /// Input is only sent while enabled. Disabling releases everything held.
    var isEnabled = false {
        didSet {
            if !isEnabled {
                releaseAll()
            }
        }
    }

    /// Size of the video, used to find where it's shown within a view.
    var videoSize: CGSize?

    private var keysDown: Set<VirtualKey> = []
    private var buttonsDown: Set<SLMouseButton> = []
    private var touchesDown: Set<UInt32> = []

    // Fractions of a unit left over from earlier events
    private var pendingMotion = CGVector.zero
    private var pendingScroll = CGVector.zero

    /// Where the video is shown within `bounds`, matching the display layer's
    /// aspect fit gravity.
    func videoRect(in bounds: CGRect) -> CGRect {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    // MARK: - Keyboard

    func setKey(_ key: VirtualKey, pressed: Bool) {
        guard isEnabled else { return }
        if pressed {
            keysDown.insert(key)
        } else if keysDown.remove(key) == nil {
            // Pressed before input was enabled
            return
        }
        send(key, pressed: pressed)
    }

    private func send(_ key: VirtualKey, pressed: Bool) {
        var modifiers = modifiers
        if key.isExtended {
            modifiers.insert(.extended)
        }
        SLInputSendKey(key.code, pressed, modifiers, key.isNonNormalized)
    }

    private var modifiers: SLKeyModifiers {
        var modifiers: SLKeyModifiers = []
        if keysDown.contains(.leftShift) || keysDown.contains(.rightShift) {
            modifiers.insert(.shift)
        }
        if keysDown.contains(.leftControl) || keysDown.contains(.rightControl) {
            modifiers.insert(.control)
        }
        if keysDown.contains(.leftAlt) || keysDown.contains(.rightAlt) {
            modifiers.insert(.alt)
        }
        if keysDown.contains(.leftMeta) || keysDown.contains(.rightMeta) {
            modifiers.insert(.meta)
        }
        return modifiers
    }

    // MARK: - Mouse

    /// Moves the host cursor by a relative amount in pixels, positive `dy`
    /// moving down.
    func moveMouse(dx: Double, dy: Double) {
        guard isEnabled else { return }
        pendingMotion.dx += dx
        pendingMotion.dy += dy
        let x = Self.takeWhole(&pendingMotion.dx)
        let y = Self.takeWhole(&pendingMotion.dy)
        if x != 0 || y != 0 {
            SLInputSendMouseMove(x, y)
        }
    }

    /// Moves the host cursor to `location` in a view whose `bounds` show the
    /// video with aspect fit.
    func moveMouse(to location: CGPoint, in bounds: CGRect) {
        guard isEnabled else { return }
        let rect = videoRect(in: bounds)
        guard rect.width >= 1, rect.height >= 1 else { return }
        // Clamp rather than drop, so the cursor still reaches the edges
        let x = min(max(location.x - rect.minX, 0), rect.width - 1)
        let y = min(max(location.y - rect.minY, 0), rect.height - 1)
        SLInputSendMousePosition(Int16(x), Int16(y), Int16(clamping: Int(rect.width)), Int16(clamping: Int(rect.height)))
    }

    func setMouseButton(_ button: SLMouseButton, pressed: Bool) {
        guard isEnabled else { return }
        if pressed {
            guard buttonsDown.insert(button).inserted else { return }
        } else {
            guard buttonsDown.remove(button) != nil else { return }
        }
        SLInputSendMouseButton(button, pressed)
    }

    /// Scrolls by an amount in wheel notches, positive values scrolling up
    /// and right.
    func scroll(vertical: Double, horizontal: Double) {
        guard isEnabled else { return }
        // 120 is one notch on Windows (WHEEL_DELTA)
        pendingScroll.dy += vertical * 120
        pendingScroll.dx += horizontal * 120
        let y = Self.takeWhole(&pendingScroll.dy)
        let x = Self.takeWhole(&pendingScroll.dx)
        if x != 0 || y != 0 {
            SLInputSendScroll(y, x)
        }
    }

    private static func takeWhole(_ value: inout CGFloat) -> Int16 {
        let whole = Int16(clamping: Int(value.rounded(.towardZero)))
        value -= CGFloat(whole)
        return whole
    }

    // MARK: - Touch

    /// `location` is in a view whose `bounds` show the video with aspect fit.
    /// `radius` is the contact radius in the same units, 0 if unknown.
    func sendTouch(_ type: SLTouchEventType, id: UInt32, at location: CGPoint, in bounds: CGRect,
                   pressure: Double, radius: Double) {
        guard isEnabled else { return }
        switch type {
        case .down:
            touchesDown.insert(id)
        case .up, .cancel:
            guard touchesDown.remove(id) != nil else { return }
        default:
            guard touchesDown.contains(id) else { return }
        }

        let rect = videoRect(in: bounds)
        guard rect.width > 0, rect.height > 0 else { return }
        let x = min(max((location.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((location.y - rect.minY) / rect.height, 0), 1)
        let contact = Float(radius * 2 / rect.width)
        SLInputSendTouch(type, id, Float(x), Float(y), Float(min(max(pressure, 0), 1)), contact, contact)
    }

    func cancelTouches() {
        guard !touchesDown.isEmpty else { return }
        touchesDown.removeAll()
        SLInputSendTouch(.cancelAll, 0, 0, 0, 0, 0, 0)
    }

    // MARK: - Focus

    /// Lets go of every key, button and touch, e.g. when focus moves away and
    /// their release events won't arrive.
    func releaseAll() {
        let keys = keysDown
        keysDown.removeAll()
        for key in keys {
            send(key, pressed: false)
        }
        for button in buttonsDown {
            SLInputSendMouseButton(button, false)
        }
        buttonsDown.removeAll()
        cancelTouches()
        pendingMotion = .zero
        pendingScroll = .zero
    }
}
