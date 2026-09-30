//
//  MoonlightClient.swift
//  Starlight
//
//  The Swift side of the moonlight-common-c bridge's session. It turns the C
//  callbacks into events and forwards media to the renderers. Input is sent by
//  StreamInput.
//

import AVFoundation
import MoonlightBridge

nonisolated struct MoonlightConfiguration: Sendable {
    var address: String
    var appVersion: String
    var gfeVersion: String?
    var rtspSessionURL: String?
    var serverCodecModeSupport: Int

    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var audioChannelCount: Int
    var videoFormats: VideoFormats
    var fullColorRange: Bool

    var remoteInputKey: Data
    var remoteInputKeyID: UInt32
}

/// Video formats the client can decode, matching moonlight-common-c's values.
nonisolated struct VideoFormats: OptionSet, Sendable {
    let rawValue: Int32

    static let h264 = VideoFormats(rawValue: SLVideoFormat.H264.rawValue)
    static let hevc = VideoFormats(rawValue: SLVideoFormat.H265.rawValue)
    static let hevcMain10 = VideoFormats(rawValue: SLVideoFormat.h265Main10.rawValue)
    static let hevcRExt8_444 = VideoFormats(rawValue: SLVideoFormat.h265RExt8_444.rawValue)
    static let hevcRExt10_444 = VideoFormats(rawValue: SLVideoFormat.h265RExt10_444.rawValue)
    static let av1Main8 = VideoFormats(rawValue: SLVideoFormat.av1Main8.rawValue)
    static let av1Main10 = VideoFormats(rawValue: SLVideoFormat.av1Main10.rawValue)

    static let h264Mask = VideoFormats(rawValue: SL_VIDEO_FORMAT_MASK_H264)
    static let hevcMask = VideoFormats(rawValue: SL_VIDEO_FORMAT_MASK_H265)
    static let av1Mask = VideoFormats(rawValue: SL_VIDEO_FORMAT_MASK_AV1)
    static let tenBitMask = VideoFormats(rawValue: SL_VIDEO_FORMAT_MASK_10BIT)
    static let yuv444Mask: VideoFormats = [
        VideoFormats(rawValue: SLVideoFormat.h264High8_444.rawValue),
        .hevcRExt8_444, .hevcRExt10_444,
        VideoFormats(rawValue: SLVideoFormat.av1High8_444.rawValue),
        VideoFormats(rawValue: SLVideoFormat.av1High10_444.rawValue),
    ]
}

/// A frame handed to the video renderer. `data` is only valid during the call.
nonisolated struct VideoFrame {
    let isKeyFrame: Bool
    /// Gaps in the numbering are frames lost on the way.
    let frameNumber: Int
    /// 0 when the host doesn't report it.
    let hostProcessingLatencyMs: Double
    /// H.264 and HEVC parameter sets without start codes, only on key frames.
    let parameterSets: [Data]
    /// Length prefixed NAL units for H.264 and HEVC, OBUs for AV1.
    let data: UnsafeRawBufferPointer
}

nonisolated struct HDRMetadata: Equatable, Sendable {
    var masteringDisplayColorVolume: Data?
    var contentLightLevelInfo: Data?
}

nonisolated protocol MoonlightVideoRenderer: AnyObject, Sendable {
    func setUp(formats: VideoFormats, width: Int, height: Int, fps: Int) -> Bool
    func cleanUp()
    /// Returns false to request a key frame.
    func submit(_ frame: VideoFrame) -> Bool
    func setHDRMetadata(_ metadata: HDRMetadata?)
}

nonisolated protocol MoonlightAudioRenderer: AnyObject, Sendable {
    /// Starts pulling audio with MoonlightClient.renderAudio(_:frameCount:).
    func start(channelCount: Int, sampleRate: Int) -> Bool
    func stop()
}

nonisolated final class MoonlightClient: @unchecked Sendable {
    enum Event: Sendable {
        case stageStarting(String)
        case stageFailed(stage: String, errorCode: Int, ports: String?)
        case connectionStarted
        /// `errorCode` is 0 when the host ended the session normally.
        case connectionTerminated(errorCode: Int, ports: String?)
        case connectionStatusChanged(isPoor: Bool)
    }

    static let noVideoTrafficError = -100
    static let noVideoFrameError = -101
    static let protectedContentError = -103

    let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let videoRenderer: any MoonlightVideoRenderer
    private let audioRenderer: any MoonlightAudioRenderer

    /// Extra query parameters for /launch and /resume.
    static var launchQueryParameters: String {
        String(cString: SLStreamLaunchQueryParameters())
    }

    static func surroundAudioInfo(channelCount: Int) -> Int {
        Int(SLStreamSurroundAudioInfo(Int32(channelCount)))
    }

    init(videoRenderer: any MoonlightVideoRenderer, audioRenderer: any MoonlightAudioRenderer) {
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Connects to the host, blocking until the stream is up. Must be balanced
    /// by stop(), even when it fails.
    func start(_ configuration: MoonlightConfiguration) -> Int32 {
        var config = SLStreamConfiguration()
        config.serverCodecModeSupport = Int32(truncatingIfNeeded: configuration.serverCodecModeSupport)
        config.width = Int32(configuration.width)
        config.height = Int32(configuration.height)
        config.fps = Int32(configuration.fps)
        config.bitrateKbps = Int32(configuration.bitrateKbps)
        config.audioChannelCount = Int32(configuration.audioChannelCount)
        config.supportedVideoFormats = configuration.videoFormats.rawValue
        config.colorSpace = configuration.videoFormats.isDisjoint(with: .tenBitMask) ? .rec709 : .rec2020
        config.fullColorRange = configuration.fullColorRange
        config.remoteInputKeyID = configuration.remoteInputKeyID
        withUnsafeMutableBytes(of: &config.remoteInputKey) { key in
            _ = configuration.remoteInputKey.copyBytes(to: key)
        }

        var callbacks = SLStreamCallbacks()
        // Released in stop(), after the bridge has stopped calling back
        callbacks.context = Unmanaged.passRetained(self).toOpaque()
        Self.installCallbacks(&callbacks)

        return configuration.address.withCString { address in
            configuration.appVersion.withCString { appVersion in
                withOptionalCString(configuration.gfeVersion) { gfeVersion in
                    withOptionalCString(configuration.rtspSessionURL) { rtspSessionURL in
                        config.address = address
                        config.appVersion = appVersion
                        config.gfeVersion = gfeVersion
                        config.rtspSessionURL = rtspSessionURL
                        return SLStreamStart(&config, &callbacks)
                    }
                }
            }
        }
    }

    /// Tears the session down, blocking until the bridge is done with us.
    func stop() {
        SLStreamStop()
        eventContinuation.finish()
        Unmanaged.passUnretained(self).release()
    }

    static func requestKeyFrame() {
        SLStreamRequestKeyFrame()
    }

    /// The estimated round trip time to the host, nil when not connected.
    static func roundTripTimeMs() -> Int? {
        var roundTripTime: UInt32 = 0
        guard SLStreamGetRoundTripTime(&roundTripTime, nil) else { return nil }
        return Int(roundTripTime)
    }

    static func hdrMetadata() -> HDRMetadata? {
        var metadata = SLHDRMetadata()
        guard SLStreamGetHDRMetadata(&metadata) else { return nil }
        return HDRMetadata(
            masteringDisplayColorVolume: metadata.hasMasteringDisplayColorVolume
                ? withUnsafeBytes(of: metadata.masteringDisplayColorVolume) { Data($0) }
                : nil,
            contentLightLevelInfo: metadata.hasContentLightLevelInfo
                ? withUnsafeBytes(of: metadata.contentLightLevelInfo) { Data($0) }
                : nil
        )
    }

    /// Fills the non-interleaved buffers with decoded audio. Real-time safe.
    static func renderAudio(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let count = buffers.count
        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: count) { channels in
            for index in 0..<count {
                channels[index] = buffers[index].mData?.assumingMemoryBound(to: Float.self)
            }
            SLStreamRenderAudio(channels.baseAddress, Int32(count), Int32(frameCount))
        }
    }

    // MARK: - Callbacks

    fileprivate static func client(_ context: UnsafeMutableRawPointer?) -> MoonlightClient {
        Unmanaged<MoonlightClient>.fromOpaque(context!).takeUnretainedValue()
    }

    fileprivate static func describePorts(_ flags: UInt32) -> String? {
        guard flags != 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 512)
        SLStreamDescribePorts(flags, &buffer, Int32(buffer.count))
        return String(cString: buffer)
    }

    private static func installCallbacks(_ callbacks: inout SLStreamCallbacks) {
        callbacks.stageStarting = { context, _, name in
            MoonlightClient.client(context).eventContinuation.yield(.stageStarting(String(cString: name!)))
        }
        callbacks.stageFailed = { context, _, name, errorCode, portFlags in
            MoonlightClient.client(context).eventContinuation.yield(.stageFailed(
                stage: String(cString: name!),
                errorCode: Int(errorCode),
                ports: MoonlightClient.describePorts(portFlags)
            ))
        }
        callbacks.connectionStarted = { context in
            MoonlightClient.client(context).eventContinuation.yield(.connectionStarted)
        }
        callbacks.connectionTerminated = { context, errorCode, portFlags in
            MoonlightClient.client(context).eventContinuation.yield(.connectionTerminated(
                errorCode: Int(errorCode),
                ports: MoonlightClient.describePorts(portFlags)
            ))
        }
        callbacks.connectionStatusChanged = { context, isPoor in
            MoonlightClient.client(context).eventContinuation.yield(.connectionStatusChanged(isPoor: isPoor))
        }
        callbacks.hdrModeChanged = { context, enabled in
            MoonlightClient.client(context).videoRenderer
                .setHDRMetadata(enabled ? MoonlightClient.hdrMetadata() ?? HDRMetadata() : nil)
        }
        callbacks.log = { _, message in
            let text = String(cString: message!).trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                print("[moonlight] \(text)")
            }
        }

        callbacks.videoSetup = { context, format, width, height, fps in
            let ok = MoonlightClient.client(context).videoRenderer.setUp(
                formats: VideoFormats(rawValue: format.rawValue),
                width: Int(width),
                height: Int(height),
                fps: Int(fps)
            )
            return ok ? 0 : -1
        }
        callbacks.videoCleanup = { context in
            MoonlightClient.client(context).videoRenderer.cleanUp()
        }
        callbacks.videoSubmitFrame = { context, frame in
            let frame = frame!.pointee
            var parameterSets: [Data] = []
            if let sets = frame.parameterSets {
                parameterSets = (0..<Int(frame.parameterSetCount)).map {
                    Data(bytes: sets[$0].data, count: Int(sets[$0].length))
                }
            }
            let videoFrame = VideoFrame(
                isKeyFrame: frame.isKeyFrame,
                frameNumber: Int(frame.frameNumber),
                hostProcessingLatencyMs: Double(frame.hostProcessingLatencyMs),
                parameterSets: parameterSets,
                data: UnsafeRawBufferPointer(start: frame.data, count: Int(frame.length))
            )
            return MoonlightClient.client(context).videoRenderer.submit(videoFrame) ? .OK : .needKeyFrame
        }

        callbacks.audioSetup = { context, channelCount, sampleRate in
            MoonlightClient.client(context).audioRenderer.start(channelCount: Int(channelCount), sampleRate: Int(sampleRate)) ? 0 : -1
        }
        callbacks.audioCleanup = { context in
            MoonlightClient.client(context).audioRenderer.stop()
        }
    }
}

nonisolated private func withOptionalCString<Result>(
    _ string: String?,
    _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}
