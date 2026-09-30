//
//  StreamSettings.swift
//  Starlight
//

import Foundation
import VideoToolbox

/// User preferences sent to the host in `/launch` and the RTSP handshake.
nonisolated enum StreamSettings {
    enum Key {
        static let resolution = "stream.resolution"
        static let frameRate = "stream.frameRate"
        static let bitrateKbps = "stream.bitrateKbps"
        static let codec = "stream.codec"
        static let hdr = "stream.hdr"
        static let colorRange = "stream.colorRange"
        static let audio = "stream.audio"
    }

    static let frameRates = [30, 60, 90, 120]
    static let bitrateRangeKbps = 500...150_000

    static let defaultResolution = StreamResolution.r1080p
    static let defaultFrameRate = 60

    static let defaultBitrateKbps = recommendedBitrateKbps(for: defaultResolution.fixedSize!, frameRate: defaultFrameRate)

    /// Moonlight's default bitrate heuristic: interpolate a factor from the
    /// pixel count, then scale by frame rate (sub-linearly above 60 FPS).
    static func recommendedBitrateKbps(for size: PixelSize, frameRate: Int) -> Int {
        let pixelVals: [Double] = [640 * 360, 854 * 480, 1280 * 720, 1920 * 1080, 2560 * 1440, 3840 * 2160]
        let factorVals: [Double] = [1, 2, 5, 10, 20, 40]
        let pixels = Double(size.width * size.height)

        var resolutionFactor = factorVals.last!
        for i in pixelVals.indices where pixels <= pixelVals[i] {
            if i == 0 {
                resolutionFactor = factorVals[0]
            } else {
                let t = (pixels - pixelVals[i - 1]) / (pixelVals[i] - pixelVals[i - 1])
                resolutionFactor = factorVals[i - 1] + t * (factorVals[i] - factorVals[i - 1])
            }
            break
        }

        let fps = Double(frameRate)
        let frameRateFactor = (fps <= 60 ? fps : (fps / 60).squareRoot() * 60) / 30
        let kbps = Int((resolutionFactor * frameRateFactor).rounded()) * 1000
        return min(max(kbps, bitrateRangeKbps.lowerBound), bitrateRangeKbps.upperBound)
    }
}

/// The settings a session starts with, read from what SettingsView stores.
nonisolated struct ResolvedStreamSettings: Sendable {
    var size: PixelSize
    var frameRate: Int
    var bitrateKbps: Int
    var codec: VideoCodecPreference
    var hdr: Bool
    var colorRange: StreamColorRange
    var audio: StreamAudioConfiguration

    @MainActor
    static func load(from defaults: UserDefaults = .standard) -> ResolvedStreamSettings {
        typealias Key = StreamSettings.Key
        let resolution = defaults.string(forKey: Key.resolution).flatMap(StreamResolution.init(rawValue:))
            ?? StreamSettings.defaultResolution
        let frameRate = defaults.object(forKey: Key.frameRate) as? Int ?? StreamSettings.defaultFrameRate
        let bitrate = defaults.object(forKey: Key.bitrateKbps) as? Int ?? StreamSettings.defaultBitrateKbps
        return ResolvedStreamSettings(
            size: resolution.pixelSize,
            frameRate: frameRate,
            bitrateKbps: min(max(bitrate, StreamSettings.bitrateRangeKbps.lowerBound), StreamSettings.bitrateRangeKbps.upperBound),
            codec: defaults.string(forKey: Key.codec).flatMap(VideoCodecPreference.init(rawValue:)) ?? .auto,
            hdr: defaults.bool(forKey: Key.hdr),
            colorRange: defaults.string(forKey: Key.colorRange).flatMap(StreamColorRange.init(rawValue:)) ?? .limited,
            audio: defaults.string(forKey: Key.audio).flatMap(StreamAudioConfiguration.init(rawValue:)) ?? .stereo
        )
    }
}

nonisolated struct PixelSize: Hashable, Sendable {
    var width: Int
    var height: Int
}

nonisolated enum StreamResolution: String, CaseIterable, Identifiable {
    case r720p = "1280x720"
    case r1080p = "1920x1080"
    case r1440p = "2560x1440"
    case r2160p = "3840x2160"
    /// The display area that avoids the notch or sensor housing.
    case safeArea
    /// The whole display, including the notch area.
    case fullScreen

    var id: Self { self }

    /// Options that make sense on this platform. visionOS has no fixed display
    /// to match, so only the presets are offered there.
    static var availableCases: [StreamResolution] {
#if os(visionOS)
        allCases.filter { $0.fixedSize != nil }
#else
        allCases
#endif
    }

    var title: String {
        switch self {
        case .r720p: "720p"
        case .r1080p: "1080p"
        case .r1440p: "1440p"
        case .r2160p: "4K"
        case .safeArea: "安全区域"
        case .fullScreen: "全屏"
        }
    }

    /// Size of the preset options; `nil` for options that follow the display.
    var fixedSize: PixelSize? {
        switch self {
        case .r720p: PixelSize(width: 1280, height: 720)
        case .r1080p: PixelSize(width: 1920, height: 1080)
        case .r1440p: PixelSize(width: 2560, height: 1440)
        case .r2160p: PixelSize(width: 3840, height: 2160)
        case .safeArea, .fullScreen: nil
        }
    }

    /// The stream size in pixels, resolving display-based options against the
    /// current display. Falls back to 1080p if the display can't be measured.
    @MainActor
    var pixelSize: PixelSize {
        if let fixedSize {
            return fixedSize
        }
        return DisplayMetrics.streamSize(useSafeArea: self == .safeArea)
            ?? StreamResolution.r1080p.fixedSize!
    }
}

nonisolated enum VideoCodecPreference: String, CaseIterable, Identifiable {
    case auto
    case h264
    case hevc
    case av1

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "自动"
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .av1: "AV1"
        }
    }

    var supportsHDR: Bool { self != .h264 }

    var isHardwareDecodeSupported: Bool {
        switch self {
        case .auto, .h264: true
        case .hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        case .av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }
    }

    /// The formats to offer the host. The host picks AV1 over HEVC over H.264,
    /// so this decides the codec while keeping fallbacks the device can decode.
    func videoFormats(hdr: Bool) -> VideoFormats {
        var formats: VideoFormats = .h264
        guard self != .h264 else { return formats }

        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            formats.insert(.hevc)
            if hdr {
                formats.insert(.hevcMain10)
            }
        }
        if self == .av1, VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
            formats.insert(.av1Main8)
            if hdr {
                formats.insert(.av1Main10)
            }
        }
        return formats
    }
}

nonisolated enum StreamColorRange: String, CaseIterable, Identifiable {
    case limited
    case full

    var id: Self { self }

    var title: String {
        switch self {
        case .limited: "有限"
        case .full: "完整"
        }
    }
}

nonisolated enum StreamAudioConfiguration: String, CaseIterable, Identifiable {
    case stereo
    case surround51
    case surround71

    var id: Self { self }

    var title: String {
        switch self {
        case .stereo: "立体声"
        case .surround51: "5.1 环绕声"
        case .surround71: "7.1 环绕声"
        }
    }

    var channelCount: Int {
        switch self {
        case .stereo: 2
        case .surround51: 6
        case .surround71: 8
        }
    }
}
