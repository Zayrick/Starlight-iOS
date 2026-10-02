//
//  StreamSurface+UIKit.swift
//  Starlight
//
//  Shows the video and turns touches, the keyboard and the mouse into host
//  input. Touches are sent as native multi-touch, which only Sunshine hosts
//  support, or drive the mouse like a trackpad or by tapping where it should
//  click (see TouchMouse). Mouse buttons, scrolling and relative motion come from GCMouse
//  when available, since UIKit doesn't report motion while the pointer is
//  locked or buttons past the second.
//

#if os(iOS) || os(visionOS)
import AVFoundation
import GameController
import MoonlightBridge
import SwiftUI
import UIKit

struct StreamSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let input: StreamInput
    let isActive: Bool
    let touchEnabled: Bool
    let touchMode: TouchMode
    let mouseMode: MouseMode

    func makeUIView(context: Context) -> StreamSurfaceView {
        StreamSurfaceView(hostedLayer: layer, input: input)
    }

    func updateUIView(_ view: StreamSurfaceView, context: Context) {
        view.isActive = isActive
        view.touchEnabled = touchEnabled
        view.touchMode = touchMode
        view.mouseMode = mouseMode
    }
}

final class StreamSurfaceView: UIView {
    private let hostedLayer: CALayer
    private let input: StreamInput

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            updatePointerLock()
            if isActive {
                becomeFirstResponder()
            }
        }
    }

    var touchEnabled = true {
        didSet {
            if !touchEnabled {
                cancelTouches()
            }
        }
    }

    var touchMode = TouchMode.multiTouch {
        didSet {
            guard touchMode != oldValue else { return }
            cancelTouches()
#if os(iOS)
            touchMouse.mode = touchMode
#endif
        }
    }

    var mouseMode = MouseMode.remoteCursor {
        didSet {
            guard mouseMode != oldValue else { return }
            updatePointerLock()
#if os(iOS)
            pointerInteraction?.invalidate()
#endif
        }
    }

    /// Host pointer IDs of the touches on screen.
    private var touchIDs: [ObjectIdentifier: UInt32] = [:]
    /// Buttons held according to UIKit, only used without a GCMouse.
    private var pointerButtons: UIEvent.ButtonMask = []
    private var lastScrollTranslation = CGPoint.zero

#if os(iOS)
    private lazy var touchMouse = TouchMouse(mode: touchMode, input: input)
    private var pointerInteraction: UIPointerInteraction?
    private var mouseObservers: [NSObjectProtocol] = []
#endif

    init(hostedLayer: CALayer, input: StreamInput) {
        self.hostedLayer = hostedLayer
        self.input = input
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        layer.addSublayer(hostedLayer)

        // Scroll wheels and two finger trackpad scrolling, without touches
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)

#if os(iOS)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        hover.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        addGestureRecognizer(hover)

        let pointerInteraction = UIPointerInteraction(delegate: self)
        addInteraction(pointerInteraction)
        self.pointerInteraction = pointerInteraction
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer.frame = bounds
        CATransaction.commit()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneWillDeactivate),
                name: UIScene.willDeactivateNotification, object: window?.windowScene
            )
        } else {
            NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
        }
#if os(iOS)
        if window != nil {
            observeMice()
        } else {
            stopObservingMice()
        }
#endif
        updatePointerLock()
    }

    /// Nothing held down gets a release event once the scene is in the
    /// background, so let go of it now.
    @objc private func sceneWillDeactivate() {
        touchIDs.removeAll()
#if os(iOS)
        touchMouse.reset()
#endif
        pointerButtons = []
        input.releaseAll()
    }

    // MARK: - Keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, pressed: true) }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, pressed: false) }
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handle($0, pressed: false) }
        if !unhandled.isEmpty {
            super.pressesCancelled(unhandled, with: event)
        }
    }

    private func handle(_ press: UIPress, pressed: Bool) -> Bool {
        guard isActive, let key = press.key, let virtualKey = VirtualKey(hidUsage: key.keyCode.rawValue) else {
            return false
        }
        // Command and its shortcuts are left to the system
        if virtualKey.isMeta || (pressed && key.modifierFlags.contains(.command)) {
            return false
        }
        input.setKey(virtualKey, pressed: pressed)
        return true
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
#if os(iOS)
        if touchEnabled, touchMode != .multiTouch {
            let fingers = touches.filter(\.isDirect)
            if !fingers.isEmpty {
                touchMouse.touchesBegan(fingers.sorted { $0.timestamp < $1.timestamp }, in: self)
            }
        }
#endif
        for touch in touches {
            switch touch.type {
            case .indirectPointer:
                pointerMoved(touch)
                updatePointerButtons(event, released: false)
#if os(iOS)
            case .direct, .pencil:
                guard touchEnabled, touchMode == .multiTouch else { continue }
                let id = (0...UInt32.max).first { !touchIDs.values.contains($0) }!
                touchIDs[ObjectIdentifier(touch)] = id
                send(touch, .down)
#endif
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
#if os(iOS)
        if touches.contains(where: \.isDirect) {
            touchMouse.touchesMoved(in: self)
        }
#endif
        for touch in touches {
            if touch.type == .indirectPointer {
                // Hovering stops while a button is held, so drags land here
                pointerMoved(touch)
            } else {
                send(touch, .move)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event: event, type: .up)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches, event: event, type: .cancel)
    }

    private func endTouches(_ touches: Set<UITouch>, event: UIEvent?, type: SLTouchEventType) {
#if os(iOS)
        let fingers = touches.filter(\.isDirect)
        if !fingers.isEmpty {
            touchMouse.touchesEnded(Array(fingers), cancelled: type == .cancel, in: self)
        }
#endif
        for touch in touches {
            if touch.type == .indirectPointer {
                updatePointerButtons(event, released: true)
            } else {
                send(touch, type)
                touchIDs[ObjectIdentifier(touch)] = nil
            }
        }
    }

    private func send(_ touch: UITouch, _ type: SLTouchEventType) {
        guard let id = touchIDs[ObjectIdentifier(touch)] else { return }
        let pressure = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 0
        input.sendTouch(type, id: id, at: touch.location(in: self), in: bounds,
                        pressure: pressure, radius: touch.majorRadius)
    }

    private func cancelTouches() {
        touchIDs.removeAll()
        input.cancelTouches()
#if os(iOS)
        touchMouse.reset()
#endif
    }

    // MARK: - Pointer

    /// Relative motion from GCMouse drives the host cursor instead, unless
    /// there's no GCMouse to get it from.
    private var usesPointerLocation: Bool {
#if os(iOS)
        mouseMode == .localCursor || GCMouse.current == nil
#else
        true
#endif
    }

    /// Whether GCMouse reports the buttons and scrolling.
    private var usesGameControllerMouse: Bool {
#if os(iOS)
        GCMouse.current != nil
#else
        false
#endif
    }

    private func pointerMoved(_ touch: UITouch) {
        guard usesPointerLocation else { return }
        input.moveMouse(to: touch.location(in: self), in: bounds)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard usesPointerLocation, recognizer.state == .began || recognizer.state == .changed else { return }
        input.moveMouse(to: recognizer.location(in: self), in: bounds)
    }

    private func updatePointerButtons(_ event: UIEvent?, released: Bool) {
        guard !usesGameControllerMouse, let event else { return }
        // A release event's mask holds the buttons that were released
        let buttons = released ? pointerButtons.subtracting(event.buttonMask) : event.buttonMask
        let changed = pointerButtons.symmetricDifference(buttons)
        pointerButtons = buttons

        let mapping: [(UIEvent.ButtonMask, SLMouseButton)] = [
            (.primary, .left),
            (.secondary, .right),
            (.button(3), .middle),
            (.button(4), .X1),
            (.button(5), .X2),
        ]
        for (mask, button) in mapping where changed.contains(mask) {
            input.setMouseButton(button, pressed: buttons.contains(mask))
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            break
        default:
            lastScrollTranslation = .zero
            return
        }
        let translation = recognizer.translation(in: self)
        defer { lastScrollTranslation = translation }
        guard !usesGameControllerMouse, bounds.height > 0 else { return }

        // A swipe across the whole view scrolls 20 notches, like Moonlight.
        // Content follows the fingers, so moving down scrolls up.
        let notchesPerPoint = 20 / bounds.height
        input.scroll(
            vertical: (translation.y - lastScrollTranslation.y) * notchesPerPoint,
            horizontal: -(translation.x - lastScrollTranslation.x) * notchesPerPoint
        )
    }

    private func updatePointerLock() {
#if os(iOS)
        let controller = sequence(first: self as UIResponder, next: \.next)
            .lazy
            .compactMap { $0 as? PointerLockController }
            .first
        controller?.prefersPointerLock = window != nil && isActive && mouseMode == .remoteCursor
#endif
    }
}

#if os(iOS)
// MARK: - GCMouse

extension StreamSurfaceView {
    /// Moonlight's iOS client slows GCMouse motion down to feel like the
    /// same mouse on a PC.
    private static let mouseSpeedDivisor = 1.25

    private func observeMice() {
        guard mouseObservers.isEmpty else { return }
        for mouse in GCMouse.mice() {
            register(mouse)
        }
        mouseObservers = [
            NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let mouse = note.object as? GCMouse else { return }
                MainActor.assumeIsolated {
                    self?.register(mouse)
                }
            },
            NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let mouse = note.object as? GCMouse else { return }
                MainActor.assumeIsolated {
                    self?.unregister(mouse)
                    // Its buttons won't be released anymore
                    self?.input.releaseAll()
                }
            },
        ]
    }

    private func stopObservingMice() {
        for observer in mouseObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        mouseObservers = []
        for mouse in GCMouse.mice() {
            unregister(mouse)
        }
    }

    // Handlers run on the mouse's handler queue, which is the main queue
    private func register(_ mouse: GCMouse) {
        guard let mouseInput = mouse.mouseInput else { return }

        mouseInput.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            MainActor.assumeIsolated {
                guard let self, self.mouseMode == .remoteCursor else { return }
                // GCMouse reports upward motion as positive
                self.input.moveMouse(
                    dx: Double(deltaX) / Self.mouseSpeedDivisor,
                    dy: -Double(deltaY) / Self.mouseSpeedDivisor
                )
            }
        }

        let buttons: [(GCControllerButtonInput?, SLMouseButton)] = [
            (mouseInput.leftButton, .left),
            (mouseInput.rightButton, .right),
            (mouseInput.middleButton, .middle),
            (mouseInput.auxiliaryButtons?.first, .X1),
            (mouseInput.auxiliaryButtons?.dropFirst().first, .X2),
        ]
        for (buttonInput, button) in buttons {
            buttonInput?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    self?.input.setMouseButton(button, pressed: pressed)
                }
            }
        }

        // Six steps make a notch, like Moonlight
        mouseInput.scroll.yAxis.valueChangedHandler = { [weak self] _, value in
            MainActor.assumeIsolated {
                self?.input.scroll(vertical: Double(value) / 6, horizontal: 0)
            }
        }
        mouseInput.scroll.xAxis.valueChangedHandler = { [weak self] _, value in
            MainActor.assumeIsolated {
                self?.input.scroll(vertical: 0, horizontal: -Double(value) / 6)
            }
        }
    }

    private func unregister(_ mouse: GCMouse) {
        guard let mouseInput = mouse.mouseInput else { return }
        mouseInput.mouseMovedHandler = nil
        mouseInput.leftButton.pressedChangedHandler = nil
        mouseInput.rightButton?.pressedChangedHandler = nil
        mouseInput.middleButton?.pressedChangedHandler = nil
        mouseInput.auxiliaryButtons?.forEach { $0.pressedChangedHandler = nil }
        mouseInput.scroll.xAxis.valueChangedHandler = nil
        mouseInput.scroll.yAxis.valueChangedHandler = nil
    }
}

private extension UITouch {
    /// A finger or Apple Pencil on the screen, rather than a pointer.
    var isDirect: Bool { type == .direct || type == .pencil }
}

// MARK: - UIPointerInteractionDelegate

extension StreamSurfaceView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // The host draws its cursor into the video, which the local pointer
        // would only obscure when it isn't placing the host cursor
        mouseMode == .remoteCursor ? .hidden() : nil
    }
}
#endif
#endif
