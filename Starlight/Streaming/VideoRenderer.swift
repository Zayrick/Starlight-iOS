//
//  VideoRenderer.swift
//  Starlight
//
//  Decodes and presents the video stream with an AVSampleBufferDisplayLayer.
//

import AVFoundation
import CoreMedia
import os

nonisolated final class VideoRenderer: MoonlightVideoRenderer, @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer

    /// Called on the main actor once the first frame has been queued for display.
    var onFirstFrame: (@MainActor @Sendable () -> Void)?
    /// Called on the main actor about once a second while video arrives.
    var onStatistics: (@MainActor @Sendable (StreamStatistics) -> Void)?

    // Only touched by the decoder thread
    private var formats: VideoFormats = []
    private var formatDescription: CMVideoFormatDescription?
    private var isWaitingForKeyFrame = true
    private var hasShownFrame = false
    private var statistics = StreamStatisticsWindow()

    // Set from the control stream thread
    private let hdrMetadata = OSAllocatedUnfairLock<HDRMetadata?>(initialState: nil)

    private static let logger = Logger(subsystem: "Starlight", category: "VideoRenderer")

    @MainActor
    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        renderer = displayLayer.sampleBufferRenderer
    }

    // MARK: - MoonlightVideoRenderer

    func setUp(formats: VideoFormats, width: Int, height: Int, fps: Int) -> Bool {
        self.formats = formats
        formatDescription = nil
        isWaitingForKeyFrame = true
        statistics.reset(width: width, height: height, format: formats)
        Self.logger.info("Video \(width)x\(height)@\(fps) format 0x\(String(formats.rawValue, radix: 16))")
        return true
    }

    func cleanUp() {
        formatDescription = nil
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func setHDRMetadata(_ metadata: HDRMetadata?) {
        let changed = hdrMetadata.withLock { current in
            defer { current = metadata }
            return current != metadata
        }
        if changed {
            // The format description carries the metadata, so start over with a key frame
            MoonlightClient.requestKeyFrame()
        }
    }

    func submit(_ frame: VideoFrame) -> Bool {
        if let statistics = statistics.record(
            frameNumber: frame.frameNumber,
            byteCount: frame.data.count,
            hostLatencyMs: frame.hostProcessingLatencyMs,
            roundTripTimeMs: MoonlightClient.roundTripTimeMs
        ), let onStatistics {
            Task { @MainActor in onStatistics(statistics) }
        }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            if let error = renderer.error {
                Self.logger.error("Video renderer failed: \(error.localizedDescription)")
            }
            renderer.flush()
            isWaitingForKeyFrame = true
            return false
        }

        if frame.isKeyFrame {
            guard let description = makeFormatDescription(for: frame) else {
                return false
            }
            formatDescription = description
            isWaitingForKeyFrame = false
        } else if isWaitingForKeyFrame {
            // Already asked for one, don't keep asking
            return true
        }

        guard let formatDescription, let sampleBuffer = makeSampleBuffer(frame.data, formatDescription) else {
            return false
        }
        renderer.enqueue(sampleBuffer)

        if !hasShownFrame {
            hasShownFrame = true
            if let onFirstFrame {
                Task { @MainActor in onFirstFrame() }
            }
        }
        return true
    }

    // MARK: - Format descriptions

    private func makeFormatDescription(for frame: VideoFrame) -> CMVideoFormatDescription? {
        let metadata = hdrMetadata.withLock { $0 }
        var extensions: [CFString: Any] = [:]
        if let data = metadata?.masteringDisplayColorVolume {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = data
        }
        if let data = metadata?.contentLightLevelInfo {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = data
        }

        var description: CMVideoFormatDescription?
        let status: OSStatus

        if !formats.isDisjoint(with: .av1Mask) {
            guard let sequenceHeader = AV1SequenceHeader(obus: frame.data) else {
                Self.logger.error("No AV1 sequence header in key frame")
                return nil
            }
            extensions.merge(sequenceHeader.formatDescriptionExtensions) { $1 }
            status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_AV1,
                width: Int32(sequenceHeader.maxFrameWidth),
                height: Int32(sequenceHeader.maxFrameHeight),
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &description
            )
        } else {
            guard !frame.parameterSets.isEmpty else {
                Self.logger.error("Key frame without parameter sets")
                return nil
            }
            let isHEVC = !formats.isDisjoint(with: .hevcMask)
            status = Self.withParameterSets(frame.parameterSets) { pointers, sizes in
                if isHEVC {
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointers.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: extensions as CFDictionary,
                        formatDescriptionOut: &description
                    )
                } else {
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointers.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description
                    )
                }
            }
        }

        guard status == noErr, let description else {
            Self.logger.error("Failed to create format description: \(status)")
            return nil
        }
        return description
    }

    private static func withParameterSets<Result>(
        _ parameterSets: [Data],
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>, UnsafeBufferPointer<Int>) -> Result
    ) -> Result {
        let joined = parameterSets.reduce(into: [UInt8]()) { $0 += $1 }
        let sizes = parameterSets.map(\.count)
        return joined.withUnsafeBufferPointer { bytes in
            var offset = 0
            let pointers = sizes.map { size in
                defer { offset += size }
                return bytes.baseAddress! + offset
            }
            return pointers.withUnsafeBufferPointer { pointers in
                sizes.withUnsafeBufferPointer { sizes in
                    body(pointers, sizes)
                }
            }
        }
    }

    // MARK: - Sample buffers

    private func makeSampleBuffer(
        _ data: UnsafeRawBufferPointer,
        _ formatDescription: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        guard let baseAddress = data.baseAddress, !data.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer,
              CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
              ) == noErr else {
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        // Frames arrive paced by the host, so show each one as soon as it's decoded
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
