//
//  AdaptiveTriggerEffect.swift
//  Starlight
//
//  A DualSense trigger effect the way games program it on the host, played
//  back with the closest mode GCDualSenseAdaptiveTrigger has.
//
//  The DualSense divides a trigger's travel into 10 zones. Most effects take a
//  10-bit mask of zones and 3-bit strengths packed after it; the older ones
//  take positions and strengths as whole bytes.
//

import GameController

nonisolated struct AdaptiveTriggerEffect: Sendable, Equatable {
    /// The effect's type byte.
    let type: UInt8
    /// Its 10 bytes of parameters.
    let parameters: [UInt8]
}

extension AdaptiveTriggerEffect {
    private enum Mode {
        case off
        /// Resistance from a position on.
        case feedback(start: Float, strength: Float)
        /// Resistance per zone.
        case zonedFeedback([Float])
        /// Resistance between two positions that gives way past the end,
        /// like a gun's trigger.
        case weapon(start: Float, end: Float, strength: Float)
        /// Resistance changing from one strength to another between two positions.
        case slope(start: Float, end: Float, startStrength: Float, endStrength: Float)
        /// Vibration from a position on.
        case vibration(start: Float, amplitude: Float, frequency: Float)
        /// Vibration strength per zone.
        case zonedVibration([Float], frequency: Float)
    }

    func apply(to trigger: GCDualSenseAdaptiveTrigger) {
        switch mode {
        case .off:
            trigger.setModeOff()
        case .feedback(let start, let strength):
            trigger.setModeFeedbackWithStartPosition(start, resistiveStrength: strength)
        case .zonedFeedback(let strengths):
            let s = strengths
            trigger.setModeFeedback(resistiveStrengths: .init(values: (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9])))
        case .weapon(let start, let end, let strength):
            trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case .slope(let start, let end, let startStrength, let endStrength):
            trigger.setModeSlopeFeedback(startPosition: start, endPosition: end,
                                         startStrength: startStrength, endStrength: endStrength)
        case .vibration(let start, let amplitude, let frequency):
            trigger.setModeVibrationWithStartPosition(start, amplitude: amplitude, frequency: frequency)
        case .zonedVibration(let amplitudes, let frequency):
            let a = amplitudes
            trigger.setModeVibration(amplitudes: .init(values: (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9])),
                                     frequency: frequency)
        }
    }

    private var mode: Mode {
        let p = parameters
        guard p.count >= 10 else { return .off }

        let mode: Mode = switch type {
        // Byte positions and strengths
        case 0x01:
            .feedback(start: Self.byte(p[0]), strength: Self.byte(p[1]))
        case 0x02:
            .weapon(start: Self.byte(p[0]), end: Self.byte(p[1]), strength: Self.byte(p[2]))
        case 0x06:
            .vibration(start: Self.byte(p[2]), amplitude: Self.byte(p[1]), frequency: Self.byte(p[0]))
        // Byte positions, strengths out of 10
        case 0x11:
            .feedback(start: Self.byte(p[0]), strength: Self.tenth(p[1]))
        case 0x12:
            .weapon(start: Self.byte(p[0]), end: Self.byte(p[1]), strength: Self.tenth(p[2]))
        // Zones
        case 0x21:
            .zonedFeedback(Self.zoneStrengths(p))
        case 0x22:
            // A bow: resistance building up to the end, then snapping back
            .slope(start: Self.firstZone(p), end: Self.lastZone(p),
                   startStrength: Self.eighth(p[2]), endStrength: Self.eighth(p[2] >> 3))
        case 0x25:
            .weapon(start: Self.firstZone(p), end: Self.lastZone(p), strength: Self.eighth(p[2]))
        case 0x26:
            .zonedVibration(Self.zoneStrengths(p), frequency: Self.byte(p[8]))
        case 0x23:
            // Galloping hooves, approximated by an even vibration
            .vibration(start: Self.firstZone(p), amplitude: 0.5, frequency: Self.byte(p[3]))
        case 0x27:
            // A machine alternating between two amplitudes
            .vibration(start: Self.firstZone(p),
                       amplitude: Float(max(p[2] & 7, p[2] >> 3 & 7)) / 7,
                       frequency: Self.byte(p[3]))
        default:
            .off
        }

        // Effects without any strength turn the trigger off
        return switch mode {
        case .feedback(_, let strength), .weapon(_, _, let strength):
            strength > 0 ? mode : .off
        case .slope(_, _, let startStrength, let endStrength):
            max(startStrength, endStrength) > 0 ? mode : .off
        case .vibration(_, let amplitude, let frequency):
            amplitude > 0 && frequency > 0 ? mode : .off
        case .zonedFeedback(let strengths):
            strengths.contains { $0 > 0 } ? mode : .off
        case .zonedVibration(let amplitudes, let frequency):
            amplitudes.contains { $0 > 0 } && frequency > 0 ? mode : .off
        case .off:
            .off
        }
    }

    private static func byte(_ value: UInt8) -> Float {
        Float(value) / 255
    }

    private static func tenth(_ value: UInt8) -> Float {
        min(Float(value) / 10, 1)
    }

    /// 3-bit strengths store one less than the strength out of 8.
    private static func eighth(_ value: UInt8) -> Float {
        Float(value & 7 + 1) / 8
    }

    private static func zoneMask(_ p: [UInt8]) -> UInt16 {
        (UInt16(p[0]) | UInt16(p[1]) << 8) & 0x3FF
    }

    /// Position of a zone's start, zone 9 being the end of the travel.
    private static func position(ofZone zone: Int) -> Float {
        Float(zone) / 9
    }

    private static func firstZone(_ p: [UInt8]) -> Float {
        let mask = zoneMask(p)
        return mask == 0 ? 0 : position(ofZone: mask.trailingZeroBitCount)
    }

    private static func lastZone(_ p: [UInt8]) -> Float {
        let mask = zoneMask(p)
        return mask == 0 ? 1 : position(ofZone: 15 - mask.leadingZeroBitCount)
    }

    /// Strengths of the zones in the mask, packed 3 bits each after it.
    private static func zoneStrengths(_ p: [UInt8]) -> [Float] {
        let mask = zoneMask(p)
        let packed = UInt32(p[2]) | UInt32(p[3]) << 8 | UInt32(p[4]) << 16 | UInt32(p[5]) << 24
        return (0..<10).map { zone in
            mask & 1 << zone == 0 ? 0 : eighth(UInt8(packed >> (3 * zone) & 7))
        }
    }
}
