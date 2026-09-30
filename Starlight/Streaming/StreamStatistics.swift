//
//  StreamStatistics.swift
//  Starlight
//
//  How the stream is doing, measured over the last second of video.
//

import Foundation

nonisolated struct StreamStatistics: Equatable, Sendable {
    var width: Int
    var height: Int
    /// The one format the host picked.
    var format: VideoFormats
    var frameRate: Double
    var bitsPerSecond: Double
    /// Share of the frames the host sent that never arrived, 0...1.
    var lossRate: Double
    /// Average time the host took per frame, nil when it doesn't say.
    var hostLatencyMs: Double?
    var roundTripTimeMs: Int?

    /// Loss above this is worth calling out.
    private static let highLossRate = 0.05

    struct Line {
        var text: String
        /// Whether the value is bad enough to stand out.
        var isWarning = false
    }

    /// Lines fit for an overlay. Unknown values show as dashes so that the
    /// lines don't jump around.
    var lines: [Line] {
        [
            Line(text: "\(width)×\(height)"),
            Line(text: "\(frameRate.formatted(.number.precision(.fractionLength(0)))) FPS"),
            Line(text: "\((bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"),
            Line(text: "\(roundTripTimeMs.map(String.init) ?? "--") ms"),
            Line(text: "\(hostLatencyMs.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--") ms frm."),
            Line(
                text: "\(lossRate.formatted(.percent.precision(.fractionLength(1)))) loss",
                isWarning: lossRate > Self.highLossRate
            ),
            Line(text: codecName),
        ]
    }

    private var codecName: String {
        var name = if !format.isDisjoint(with: .av1Mask) {
            "AV1"
        } else if !format.isDisjoint(with: .hevcMask) {
            "HEVC"
        } else {
            "H.264"
        }
        if !format.isDisjoint(with: .tenBitMask) {
            name += " 10-bit"
        }
        if !format.isDisjoint(with: .yuv444Mask) {
            name += " 4:4:4"
        }
        return name
    }
}

/// Collects frames on the decoder thread and turns each second of them into
/// statistics.
nonisolated struct StreamStatisticsWindow {
    private static let length = Duration.seconds(1)

    private var width = 0
    private var height = 0
    private var format: VideoFormats = []

    private var start: ContinuousClock.Instant?
    private var lastFrameNumber: Int?
    private var receivedFrames = 0
    private var lostFrames = 0
    private var bytes = 0
    private var hostLatencySumMs = 0.0
    private var hostLatencyCount = 0

    mutating func reset(width: Int, height: Int, format: VideoFormats) {
        self = StreamStatisticsWindow()
        self.width = width
        self.height = height
        self.format = format
    }

    /// Returns statistics once a full window has gone by.
    mutating func record(
        frameNumber: Int,
        byteCount: Int,
        hostLatencyMs: Double,
        roundTripTimeMs: () -> Int?
    ) -> StreamStatistics? {
        let now = ContinuousClock.now
        guard let start else {
            // The first frame only starts the clock
            self.start = now
            lastFrameNumber = frameNumber
            return nil
        }

        if let lastFrameNumber, frameNumber > lastFrameNumber + 1 {
            lostFrames += frameNumber - lastFrameNumber - 1
        }
        lastFrameNumber = frameNumber
        receivedFrames += 1
        bytes += byteCount
        if hostLatencyMs > 0 {
            hostLatencySumMs += hostLatencyMs
            hostLatencyCount += 1
        }

        let elapsed = now - start
        guard elapsed >= Self.length else { return nil }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let statistics = StreamStatistics(
            width: width,
            height: height,
            format: format,
            frameRate: Double(receivedFrames) / seconds,
            bitsPerSecond: Double(bytes * 8) / seconds,
            lossRate: Double(lostFrames) / Double(receivedFrames + lostFrames),
            hostLatencyMs: hostLatencyCount > 0 ? hostLatencySumMs / Double(hostLatencyCount) : nil,
            roundTripTimeMs: roundTripTimeMs()
        )
        self.start = now
        receivedFrames = 0
        lostFrames = 0
        bytes = 0
        hostLatencySumMs = 0
        hostLatencyCount = 0
        return statistics
    }
}
