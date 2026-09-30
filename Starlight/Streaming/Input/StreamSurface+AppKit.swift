//
//  StreamSurface+AppKit.swift
//  Starlight
//
//  Shows the video and turns the keyboard and mouse into host input. With the
//  remote cursor, the pointer is hidden and held in place while the window is
//  focused, and its motion is sent relatively. ⌃⌥⇧Z lets go of it.
//

#if os(macOS)
import AppKit
import AVFoundation
import MoonlightBridge
import SwiftUI

struct StreamSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let input: StreamInput
    let isActive: Bool
    let touchEnabled: Bool
    let mouseMode: MouseMode

    func makeNSView(context: Context) -> StreamSurfaceView {
        StreamSurfaceView(hostedLayer: layer, input: input)
    }

    func updateNSView(_ view: StreamSurfaceView, context: Context) {
        view.isActive = isActive
        view.mouseMode = mouseMode
    }

    static func dismantleNSView(_ view: StreamSurfaceView, coordinator: ()) {
        view.isActive = false
    }
}

final class StreamSurfaceView: NSView {
    private let hostedLayer: CALayer
    private let input: StreamInput

    var isActive = false {
        didSet {
            if isActive != oldValue {
                updateCapture()
            }
        }
    }

    var mouseMode = MouseMode.remoteCursor {
        didSet {
            if mouseMode != oldValue {
                updateCapture()
            }
        }
    }

    /// Whether the pointer is hidden and held in place.
    private var isCaptured = false
    /// Capture was let go with the shortcut, until the next click.
    private var isCaptureReleased = false
    private var windowObservers: [NSObjectProtocol] = []

    init(hostedLayer: CALayer, input: StreamInput) {
        self.hostedLayer = hostedLayer
        self.input = input
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(hostedLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The click that focuses the window captures the pointer right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []

        if let window {
            window.makeFirstResponder(self)
            let center = NotificationCenter.default
            windowObservers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateCapture()
                    }
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.focusLost()
                    }
                },
                center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateCapture()
                    }
                },
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.focusLost()
                    }
                },
            ]
        }
        updateCapture()
    }

    private func focusLost() {
        // Releases of what's held down now go elsewhere
        input.releaseAll()
        updateCapture()
    }

    // MARK: - Capture

    private var shouldCapture: Bool {
        guard let window else { return false }
        return isActive && mouseMode == .remoteCursor && !isCaptureReleased
            && window.isKeyWindow && NSApp.isActive
    }

    private func updateCapture() {
        let capture = shouldCapture
        guard capture != isCaptured else { return }
        isCaptured = capture

        if capture {
            // Park the pointer over the video so clicks stay in this window
            if let window, let screenHeight = NSScreen.screens.first?.frame.maxY {
                let point = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
                CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screenHeight - point.y))
            }
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    /// Whether mouse events go to the host.
    private var sendsMouse: Bool {
        isActive && (mouseMode == .localCursor || isCaptured)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        guard sendsMouse else { return }
        if mouseMode == .remoteCursor {
            input.moveMouse(dx: event.deltaX, dy: event.deltaY)
        } else {
            input.moveMouse(to: convert(event.locationInWindow, from: nil), in: bounds)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        mouseButton(.left, pressed: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseButton(.left, pressed: false, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseButton(.right, pressed: true, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseButton(.right, pressed: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if let button = Self.otherButton(event) {
            mouseButton(button, pressed: true, event: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if let button = Self.otherButton(event) {
            mouseButton(button, pressed: false, event: event)
        }
    }

    private static func otherButton(_ event: NSEvent) -> SLMouseButton? {
        switch event.buttonNumber {
        case 2: .middle
        case 3: .X1
        case 4: .X2
        default: nil
        }
    }

    private func mouseButton(_ button: SLMouseButton, pressed: Bool, event: NSEvent) {
        window?.makeFirstResponder(self)
        if pressed, mouseMode == .remoteCursor, !isCaptured {
            // This click only captures the pointer
            isCaptureReleased = false
            updateCapture()
            return
        }
        guard sendsMouse else { return }
        if mouseMode == .localCursor {
            input.moveMouse(to: convert(event.locationInWindow, from: nil), in: bounds)
        }
        input.setMouseButton(button, pressed: pressed)
    }

    override func scrollWheel(with event: NSEvent) {
        guard sendsMouse else { return }
        // Trackpads report points rather than lines, scaled down like SDL
        let scale = event.hasPreciseScrollingDeltas ? 0.1 : 1
        // Content follows the gesture, so a positive delta scrolls up or left
        input.scroll(vertical: event.scrollingDeltaY * scale, horizontal: -event.scrollingDeltaX * scale)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat, !event.modifierFlags.contains(.command) else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isSuperset(of: [.control, .option, .shift]), event.keyCode == 0x06 { // Z
            toggleCapture()
            return
        }

        if let key = VirtualKey(macKeyCode: event.keyCode) {
            input.setKey(key, pressed: true)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let key = VirtualKey(macKeyCode: event.keyCode) {
            input.setKey(key, pressed: false)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let key = VirtualKey(macKeyCode: event.keyCode), !key.isMeta else { return }

        if event.keyCode == 0x39 {
            // Caps Lock reports each press without a release
            input.setKey(key, pressed: true)
            input.setKey(key, pressed: false)
            return
        }

        // Device dependent modifier masks from IOKit's IOLLEvent.h
        let mask: UInt = switch event.keyCode {
        case 0x3B: 0x0001 // Left Control
        case 0x38: 0x0002 // Left Shift
        case 0x3C: 0x0004 // Right Shift
        case 0x3A: 0x0020 // Left Option
        case 0x3D: 0x0040 // Right Option
        case 0x3E: 0x2000 // Right Control
        default: 0
        }
        guard mask != 0 else { return }
        input.setKey(key, pressed: event.modifierFlags.rawValue & mask != 0)
    }

    /// Key combinations with Control would otherwise be taken as shortcuts.
    /// Command ones are left to the menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive, event.type == .keyDown, window?.firstResponder === self,
              !event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private func toggleCapture() {
        guard mouseMode == .remoteCursor else { return }
        isCaptureReleased = isCaptured
        // The shortcut's own keys won't be released on the host otherwise
        input.releaseAll()
        updateCapture()
    }
}
#endif
