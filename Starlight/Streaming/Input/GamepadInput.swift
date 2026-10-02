//
//  GamepadInput.swift
//  Starlight
//
//  Sends game controllers to the host as gamepads, numbered in the order they
//  connect, and plays back what the host asks of them: rumble, DualSense
//  trigger effects, motion sensor reports and the light bar color.
//
//  Controllers a phone sits in, like the Backbone, often have no motors or
//  motion sensors. The phone can stand in for them on the first gamepad.
//

import CoreHaptics
import GameController
import MoonlightBridge
#if os(iOS)
import CoreMotion
import UIKit
#endif

final class GamepadInput {
    /// Gamepads are only picked up and sent while enabled.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    /// Connected gamepads by their number on the host.
    private var gamepads: [Int: Gamepad] = [:]
    private var settings = GamepadSettings.load()
    private var observers: [NSObjectProtocol] = []
    private var batteryTimer: Timer?

    private var activeMask: UInt16 {
        gamepads.keys.reduce(0) { $0 | 1 << $1 }
    }

    // MARK: - Lifecycle

    private func start() {
        settings = GamepadSettings.load()
        for controller in GCController.controllers() {
            connect(controller)
        }
        observers = [
            NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                MainActor.assumeIsolated {
                    self?.connect(controller)
                }
            },
            NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                MainActor.assumeIsolated {
                    self?.disconnect(controller)
                }
            },
        ]

        // Battery levels change slowly and nothing reports when they do
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.gamepads.values.forEach { $0.reportBattery() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        batteryTimer?.invalidate()
        batteryTimer = nil
        // The stream is over, so there's no host left to tell
        for gamepad in gamepads.values {
            gamepad.tearDown()
        }
        gamepads = [:]
    }

    private func connect(_ controller: GCController) {
        // Micro gamepads like the Siri Remote don't have enough buttons
        guard controller.extendedGamepad != nil,
              !gamepads.values.contains(where: { $0.controller === controller }),
              let number = (0..<Int(SL_MAX_GAMEPADS)).first(where: { gamepads[$0] == nil }) else { return }

        // A controller the phone sits in is the only one, or at least the first
        let device = number == 0 && settings.usesDevice ? DeviceStandIn() : nil
        let gamepad = Gamepad(controller: controller, number: number, settings: settings, device: device)
        gamepads[number] = gamepad
        gamepad.onChange = { [weak self, weak gamepad] in
            guard let self, let gamepad else { return }
            send(gamepad)
        }
        reportArrival(of: gamepad)
    }

    private func disconnect(_ controller: GCController) {
        guard let gamepad = gamepads.values.first(where: { $0.controller === controller }) else { return }
        gamepad.tearDown()
        gamepads[gamepad.number] = nil
        guard gamepad.hasArrived else { return }
        // A zeroed state without its bit in the mask removes it from the host
        SLInputSendGamepadState(UInt8(gamepad.number), activeMask, [], 0, 0, 0, 0, 0, 0)
    }

    // MARK: - State

    /// Arrival can't be sent before the input stream is up, so it's retried
    /// with each change until it goes through.
    @discardableResult
    private func reportArrival(of gamepad: Gamepad) -> Bool {
        guard !gamepad.hasArrived else { return true }
        guard SLInputSendGamepadArrival(UInt8(gamepad.number), activeMask, gamepad.type,
                                        gamepad.supportedButtons, gamepad.capabilities) else { return false }
        gamepad.hasArrived = true
        gamepad.reportBattery()
        return true
    }

    private func send(_ gamepad: Gamepad) {
        guard isEnabled, reportArrival(of: gamepad) else { return }
        let state = gamepad.state
        SLInputSendGamepadState(UInt8(gamepad.number), activeMask, state.buttons,
                                state.leftTrigger, state.rightTrigger,
                                state.leftStick.x, state.leftStick.y,
                                state.rightStick.x, state.rightStick.y)
    }

    /// Lets go of everything held on every gamepad, e.g. when focus moves
    /// away and their updates stop arriving.
    func releaseAll() {
        for gamepad in gamepads.values where gamepad.hasArrived {
            gamepad.state = GamepadState()
            send(gamepad)
        }
    }

    // MARK: - Feedback

    func apply(_ feedback: MoonlightClient.GamepadFeedback, to number: Int) {
        guard isEnabled, let gamepad = gamepads[number] else { return }
        switch feedback {
        case .rumble(let lowFrequency, let highFrequency):
            gamepad.lowFrequencyMotor?.intensity = lowFrequency
            gamepad.highFrequencyMotor?.intensity = highFrequency
        case .triggerRumble(let left, let right):
            gamepad.leftTriggerMotor?.intensity = left
            gamepad.rightTriggerMotor?.intensity = right
        case .adaptiveTriggers(let left, let right):
            gamepad.setAdaptiveTriggers(left: left, right: right)
        case .motion(let type, let rateHz):
            gamepad.setMotionReporting(type, rateHz: rateHz)
        case .light(let red, let green, let blue):
            gamepad.controller.light?.color = GCColor(red: Float(red), green: Float(green), blue: Float(blue))
        }
    }
}

// MARK: - Gamepad

private struct GamepadState {
    var buttons: SLGamepadButtons = []
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var leftStick: (x: Int16, y: Int16) = (0, 0)
    var rightStick: (x: Int16, y: Int16) = (0, 0)
}

/// One game controller, as the host's gamepad `number`.
private final class Gamepad {
    let controller: GCController
    let number: Int
    let type: SLGamepadType
    let supportedButtons: SLGamepadButtons
    let capabilities: SLGamepadCapabilities

    var state = GamepadState()
    var hasArrived = false
    /// Called after the state changed.
    var onChange: (() -> Void)?

    let lowFrequencyMotor: RumbleMotor?
    let highFrequencyMotor: RumbleMotor?
    let leftTriggerMotor: RumbleMotor?
    let rightTriggerMotor: RumbleMotor?

    private let swapsButtons: Bool
    private let allowsFeedback: Bool
    private let motionSource: MotionSource?
    /// Requested report rates of the motion sensors.
    private var motionRates: [SLMotionType: Int] = [:]
    private var motionTimer: Timer?
    private var lastMotion: MotionSample?
    private var lastBattery: (state: GCDeviceBattery.State, level: Float)?
    /// Last positions on each touchpad, nil while not touched.
    private var touches: [CGPoint?] = [nil, nil]

    init(controller: GCController, number: Int, settings: GamepadSettings, device: DeviceStandIn?) {
        self.controller = controller
        self.number = number
        swapsButtons = settings.swapsButtons
        allowsFeedback = settings.feedback
        let gamepad = controller.extendedGamepad!
        let profile = controller.physicalInputProfile

        type = switch settings.emulation {
        case .xbox: .xbox
        case .playStation: .playStation
        case .automatic:
            switch gamepad {
            case is GCXboxGamepad: .xbox
            case is GCDualSenseGamepad, is GCDualShockGamepad: .playStation
            default: .unknown
            }
        }

        var buttons: SLGamepadButtons = [.A, .B, .X, .Y, .up, .down, .left, .right,
                                         .leftShoulder, .rightShoulder, .start]
        var capabilities: SLGamepadCapabilities = []
        if gamepad.buttonOptions != nil { buttons.insert(.back) }
        if gamepad.buttonHome != nil { buttons.insert(.guide) }
        if gamepad.leftThumbstickButton != nil { buttons.insert(.leftStick) }
        if gamepad.rightThumbstickButton != nil { buttons.insert(.rightStick) }
        for (name, button) in Self.extraButtons where profile.buttons[name] != nil {
            buttons.insert(button)
        }
        if gamepad.leftTrigger.isAnalog, gamepad.rightTrigger.isAnalog {
            capabilities.insert(.analogTriggers)
        }
        if profile.dpads[GCInputDualShockTouchpadOne] != nil {
            capabilities.insert(.touchpad)
        }
        if controller.light != nil { capabilities.insert(.light) }
        if controller.battery != nil { capabilities.insert(.battery) }

        // The handles carry a heavy motor on the left and a light one on the right
        if settings.feedback {
            lowFrequencyMotor = RumbleMotor(controller: controller, locality: .leftHandle)
                ?? device?.makeMotor(sharpness: 0.3)
            highFrequencyMotor = RumbleMotor(controller: controller, locality: .rightHandle)
                ?? device?.makeMotor(sharpness: 0.8)
            leftTriggerMotor = RumbleMotor(controller: controller, locality: .leftTrigger)
            rightTriggerMotor = RumbleMotor(controller: controller, locality: .rightTrigger)
        } else {
            lowFrequencyMotor = nil
            highFrequencyMotor = nil
            leftTriggerMotor = nil
            rightTriggerMotor = nil
        }
        if lowFrequencyMotor != nil || highFrequencyMotor != nil {
            capabilities.insert(.rumble)
        }
        if leftTriggerMotor != nil || rightTriggerMotor != nil {
            capabilities.insert(.triggerRumble)
        }

        if let motion = controller.motion, motion.hasRotationRate {
            motionSource = .controller(motion)
            capabilities.insert(.gyroscope)
            if motion.hasGravityAndUserAcceleration {
                capabilities.insert(.accelerometer)
            }
        } else if let source = device?.motionSource {
            motionSource = source
            capabilities.formUnion([.gyroscope, .accelerometer])
        } else {
            motionSource = nil
        }

        supportedButtons = buttons
        self.capabilities = capabilities

        if number < 4 {
            controller.playerIndex = GCControllerPlayerIndex(rawValue: number) ?? .indexUnset
        }
        // The Home and Share buttons belong to the host's games, not to the system
        for element in profile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        // Handlers run on the controller's handler queue, which is the main queue
        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            MainActor.assumeIsolated {
                self?.update(from: gamepad)
            }
        }
    }

    func tearDown() {
        controller.extendedGamepad?.valueChangedHandler = nil
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .enabled
        }
        controller.playerIndex = .indexUnset
        for motor in [lowFrequencyMotor, highFrequencyMotor, leftTriggerMotor, rightTriggerMotor] {
            motor?.stop()
        }
        // Trigger effects stay on the controller until turned off
        if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad, allowsFeedback {
            dualSense.leftTrigger.setModeOff()
            dualSense.rightTrigger.setModeOff()
        }
        motionRates = [:]
        updateMotionTimer()
        onChange = nil
    }

    private static let extraButtons: [(String, SLGamepadButtons)] = [
        (GCInputXboxPaddleOne, .paddle1),
        (GCInputXboxPaddleTwo, .paddle2),
        (GCInputXboxPaddleThree, .paddle3),
        (GCInputXboxPaddleFour, .paddle4),
        (GCInputButtonShare, .misc),
        (GCInputDualShockTouchpadButton, .touchpad),
    ]

    private func update(from gamepad: GCExtendedGamepad) {
        // Nintendo puts A where others put B, and X where others put Y
        let (a, b, x, y): (SLGamepadButtons, SLGamepadButtons, SLGamepadButtons, SLGamepadButtons) =
            swapsButtons ? (.B, .A, .Y, .X) : (.A, .B, .X, .Y)
        let pressed: [(GCControllerButtonInput?, SLGamepadButtons)] = [
            (gamepad.buttonA, a),
            (gamepad.buttonB, b),
            (gamepad.buttonX, x),
            (gamepad.buttonY, y),
            (gamepad.dpad.up, .up),
            (gamepad.dpad.down, .down),
            (gamepad.dpad.left, .left),
            (gamepad.dpad.right, .right),
            (gamepad.leftShoulder, .leftShoulder),
            (gamepad.rightShoulder, .rightShoulder),
            (gamepad.leftThumbstickButton, .leftStick),
            (gamepad.rightThumbstickButton, .rightStick),
            (gamepad.buttonMenu, .start),
            (gamepad.buttonOptions, .back),
            (gamepad.buttonHome, .guide),
        ]
        var buttons: SLGamepadButtons = []
        for (input, button) in pressed where input?.isPressed == true {
            buttons.insert(button)
        }
        let profile = controller.physicalInputProfile
        for (name, button) in Self.extraButtons where profile.buttons[name]?.isPressed == true {
            buttons.insert(button)
        }

        state = GamepadState(
            buttons: buttons,
            leftTrigger: Self.trigger(gamepad.leftTrigger),
            rightTrigger: Self.trigger(gamepad.rightTrigger),
            leftStick: Self.stick(gamepad.leftThumbstick),
            rightStick: Self.stick(gamepad.rightThumbstick)
        )
        onChange?()

        if hasArrived, capabilities.contains(.touchpad) {
            updateTouchpad(0, profile.dpads[GCInputDualShockTouchpadOne])
            updateTouchpad(1, profile.dpads[GCInputDualShockTouchpadTwo])
        }
    }

    private static func trigger(_ input: GCControllerButtonInput) -> UInt8 {
        UInt8(min(max(input.value, 0), 1) * 255)
    }

    private static func stick(_ input: GCControllerDirectionPad) -> (x: Int16, y: Int16) {
        // Both point up and right, like the host expects
        (Int16(min(max(input.xAxis.value, -1), 1) * 0x7FFE),
         Int16(min(max(input.yAxis.value, -1), 1) * 0x7FFE))
    }

    // MARK: Touchpad

    /// Sony touchpads report their finger as a dpad, at the center while
    /// nothing touches it.
    private func updateTouchpad(_ index: Int, _ pad: GCControllerDirectionPad?) {
        guard let pad else { return }
        let x = pad.xAxis.value
        let y = pad.yAxis.value
        let touch: CGPoint? = x == 0 && y == 0 ? nil : CGPoint(x: Double(x), y: Double(y))
        let previous = touches[index]
        guard touch != previous else { return }
        touches[index] = touch

        let type: SLTouchEventType
        let point: CGPoint
        switch (previous, touch) {
        case (nil, let touch?):
            type = .down
            point = touch
        case (_?, let touch?):
            type = .move
            point = touch
        case (let previous?, nil):
            type = .up
            point = previous
        case (nil, nil):
            return
        }
        // From -1...1 with y up to 0...1 with y down
        SLInputSendGamepadTouch(UInt8(number), type, UInt32(index),
                                Float((1 + point.x) / 2), Float((1 - point.y) / 2), 1)
    }

    // MARK: Adaptive triggers

    func setAdaptiveTriggers(left: AdaptiveTriggerEffect?, right: AdaptiveTriggerEffect?) {
        guard allowsFeedback, let dualSense = controller.extendedGamepad as? GCDualSenseGamepad else { return }
        left?.apply(to: dualSense.leftTrigger)
        right?.apply(to: dualSense.rightTrigger)
    }

    // MARK: Motion

    func setMotionReporting(_ type: SLMotionType, rateHz: Int) {
        motionRates[type] = rateHz > 0 ? rateHz : nil
        lastMotion = nil
        updateMotionTimer()
    }

    private func updateMotionTimer() {
        motionTimer?.invalidate()
        motionTimer = nil

        let rate = motionRates.values.max() ?? 0
        motionSource?.setActive(rate > 0, rateHz: rate)
        guard rate > 0 else { return }

        // Sampled at the host's rate rather than whenever the sensors update
        let timer = Timer(timeInterval: 1 / Double(rate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reportMotion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func reportMotion() {
        guard let sample = motionSource?.sample() else { return }
        let gamepad = UInt8(number)
        if motionRates[.accelerometer] != nil, let acceleration = sample.acceleration,
           acceleration != lastMotion?.acceleration {
            SLInputSendGamepadMotion(gamepad, .accelerometer, acceleration.x, acceleration.y, acceleration.z)
        }
        if motionRates[.gyroscope] != nil, sample.rotationRate != lastMotion?.rotationRate {
            SLInputSendGamepadMotion(gamepad, .gyroscope, sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z)
        }
        lastMotion = sample
    }

    // MARK: Battery

    /// Sends the battery state if it changed since last time.
    func reportBattery() {
        guard hasArrived, let battery = controller.battery else { return }
        let current = (state: battery.batteryState, level: battery.batteryLevel)
        if let lastBattery, lastBattery == current { return }
        lastBattery = current

        let state: SLBatteryState = switch current.state {
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        SLInputSendGamepadBattery(UInt8(number), state, UInt8(min(max(current.level, 0), 1) * 100))
    }
}

// MARK: - Motion

private struct Vector3: Equatable {
    var x: Float
    var y: Float
    var z: Float
}

/// Motion along SDL's gamepad axes: x to the right, y up out of the face and
/// z toward the player.
private struct MotionSample {
    /// In m/s², pointing away from gravity at rest. Nil when unknown.
    var acceleration: Vector3?
    /// In deg/s.
    var rotationRate: Vector3
}

private enum MotionSource {
    case controller(GCMotion)
#if os(iOS)
    case device(CMMotionManager)
#endif

    private static let standardGravity: Float = 9.80665
    private static let degreesPerRadian = Float(180 / Double.pi)

    func setActive(_ isActive: Bool, rateHz: Int) {
        switch self {
        case .controller(let motion):
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = isActive
            }
#if os(iOS)
        case .device(let manager):
            if isActive {
                manager.deviceMotionUpdateInterval = 1 / Double(rateHz)
                manager.startDeviceMotionUpdates()
            } else {
                manager.stopDeviceMotionUpdates()
            }
#endif
        }
    }

    func sample() -> MotionSample? {
        switch self {
        case .controller(let motion):
            // Moonlight's iOS client maps Apple's controller axes like this
            let g = -Self.standardGravity
            let d = Self.degreesPerRadian
            let rotation = motion.rotationRate
            let acceleration = motion.acceleration
            return MotionSample(
                acceleration: motion.hasGravityAndUserAcceleration
                    ? Vector3(x: Float(acceleration.x) * g, y: Float(acceleration.y) * g, z: Float(acceleration.z) * g)
                    : nil,
                rotationRate: Vector3(x: Float(rotation.x) * d, y: Float(rotation.z) * d, z: Float(-rotation.y) * d)
            )
#if os(iOS)
        case .device(let manager):
            guard let motion = manager.deviceMotion else { return nil }
            // The device's axes are x to the right of the screen, y to its top
            // and z out of it, as the device is held in portrait
            let orientation = Self.interfaceOrientation
            let total = Vector3(x: Float(motion.gravity.x + motion.userAcceleration.x),
                                y: Float(motion.gravity.y + motion.userAcceleration.y),
                                z: Float(motion.gravity.z + motion.userAcceleration.z))
            let rotation = Vector3(x: Float(motion.rotationRate.x),
                                   y: Float(motion.rotationRate.y),
                                   z: Float(motion.rotationRate.z))
            // Core Motion reports gravity itself, SDL the force holding against it
            let acceleration = Self.gamepadAxes(total, orientation)
            let rate = Self.gamepadAxes(rotation, orientation)
            let g = -Self.standardGravity
            let d = Self.degreesPerRadian
            return MotionSample(
                acceleration: Vector3(x: acceleration.x * g, y: acceleration.y * g, z: acceleration.z * g),
                rotationRate: Vector3(x: rate.x * d, y: rate.y * d, z: rate.z * d)
            )
#endif
        }
    }

#if os(iOS)
    /// Turns the device's axes into a gamepad's, as if the screen were its
    /// face: right along the screen as shown, up out of it, toward the
    /// player along the screen's shown bottom.
    private static func gamepadAxes(_ v: Vector3, _ orientation: UIInterfaceOrientation) -> Vector3 {
        switch orientation {
        case .portrait: Vector3(x: v.x, y: v.z, z: -v.y)
        case .portraitUpsideDown: Vector3(x: -v.x, y: v.z, z: v.y)
        case .landscapeRight: Vector3(x: -v.y, y: v.z, z: -v.x)
        default: Vector3(x: v.y, y: v.z, z: v.x)
        }
    }

    private static var interfaceOrientation: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.effectiveGeometry.interfaceOrientation ?? .landscapeLeft
    }
#endif
}

// MARK: - Device

/// The device's own motors and motion sensors, standing in for a controller
/// it sits in. Only phones have both.
private struct DeviceStandIn {
#if os(iOS)
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    let motionSource: MotionSource?

    init?() {
        let manager = CMMotionManager()
        motionSource = manager.isDeviceMotionAvailable ? .device(manager) : nil
        guard supportsHaptics || motionSource != nil else { return nil }
    }

    func makeMotor(sharpness: Float) -> RumbleMotor? {
        guard supportsHaptics, let engine = try? CHHapticEngine() else { return nil }
        // Keeps the stream's audio playing
        engine.playsHapticsOnly = true
        return RumbleMotor(engine: engine, sharpness: sharpness)
    }
#else
    let motionSource: MotionSource? = nil

    init?() {
        return nil
    }

    func makeMotor(sharpness: Float) -> RumbleMotor? {
        nil
    }
#endif
}

// MARK: - Rumble

/// One motor, playing a continuous effect at the strength the host asks for.
private final class RumbleMotor {
    /// 0...1, kept until changed.
    var intensity: Double = 0 {
        didSet {
            if intensity != oldValue {
                play()
            }
        }
    }

    private let engine: CHHapticEngine
    /// How crisp the effect feels, nil to leave it to the motor.
    private let sharpness: Float?
    private var player: CHHapticPatternPlayer?
    private var isRunning = false
    private var isPlaying = false

    convenience init?(controller: GCController, locality: GCHapticsLocality) {
        guard let haptics = controller.haptics, haptics.supportedLocalities.contains(locality),
              let engine = haptics.createEngine(withLocality: locality) else { return nil }
        self.init(engine: engine, sharpness: nil)
    }

    init(engine: CHHapticEngine, sharpness: Float?) {
        self.engine = engine
        self.sharpness = sharpness

        // The engine stops when the app goes to the background, and resets
        // when the haptic server restarts. Either way it starts over on demand.
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in
                self?.invalidate()
            }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.invalidate()
                self.play()
            }
        }
    }

    func stop() {
        intensity = 0
        engine.stop()
        invalidate()
    }

    private func invalidate() {
        player = nil
        isRunning = false
        isPlaying = false
    }

    private func play() {
        if intensity == 0 {
            if isPlaying {
                try? player?.stop(atTime: CHHapticTimeImmediate)
                isPlaying = false
            }
            return
        }

        do {
            if !isRunning {
                try engine.start()
                isRunning = true
            }
            let player = try player ?? makePlayer()
            self.player = player
            // Scales the full intensity of the pattern
            try player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(intensity), relativeTime: 0)],
                atTime: CHHapticTimeImmediate
            )
            if !isPlaying {
                try player.start(atTime: CHHapticTimeImmediate)
                isPlaying = true
            }
        } catch {
            invalidate()
        }
    }

    private func makePlayer() throws -> CHHapticPatternPlayer {
        var parameters = [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)]
        if let sharpness {
            parameters.append(CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness))
        }
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: parameters,
            relativeTime: 0,
            duration: TimeInterval(GCHapticDurationInfinite)
        )
        return try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
    }
}
