//
//  AV1SequenceHeader.swift
//  Starlight
//
//  Parses the AV1 sequence header OBU of a key frame, which VideoToolbox needs
//  as an `av1C` box plus color extensions to build a format description.
//

import CoreMedia
import Foundation

nonisolated struct AV1SequenceHeader {
    private(set) var profile = 0
    private(set) var levelIndex = 0
    private(set) var tier = 0
    private(set) var maxFrameWidth = 0
    private(set) var maxFrameHeight = 0
    private(set) var bitDepth = 8
    private(set) var isMonochrome = false
    private(set) var subsamplingX = 1
    private(set) var subsamplingY = 1
    private(set) var chromaSamplePosition = 0
    private(set) var colorPrimaries = 2
    private(set) var transferCharacteristics = 2
    private(set) var matrixCoefficients = 2
    private(set) var isFullRange = false
    /// The OBU itself, with a size field, as stored in `av1C`.
    private(set) var obu = Data()

    private static let sequenceHeaderOBUType = 1

    /// Finds and parses the sequence header in a temporal unit.
    init?(obus data: UnsafeRawBufferPointer) {
        let bytes = data.bindMemory(to: UInt8.self)
        var offset = 0

        while offset < bytes.count {
            let header = bytes[offset]
            let type = Int(header >> 3) & 0xF
            let hasExtension = header & 0x04 != 0
            let hasSizeField = header & 0x02 != 0
            var position = offset + 1 + (hasExtension ? 1 : 0)

            let payloadSize: Int
            if hasSizeField {
                guard let (size, length) = Self.readLEB128(bytes, at: position) else { return nil }
                payloadSize = size
                position += length
            } else {
                payloadSize = bytes.count - position
            }
            guard position + payloadSize <= bytes.count else { return nil }

            if type == Self.sequenceHeaderOBUType {
                let payload = UnsafeBufferPointer(rebasing: bytes[position..<position + payloadSize])
                guard parse(payload) else { return nil }
                obu = Data([UInt8(Self.sequenceHeaderOBUType << 3) | 0x02])
                    + Self.leb128(payloadSize)
                    + Data(payload)
                return
            }
            offset = position + payloadSize
        }
        return nil
    }

    /// Extensions for CMVideoFormatDescriptionCreate().
    var formatDescriptionExtensions: [CFString: Any] {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_FormatName: "av01",
            // YUV without alpha
            kCMFormatDescriptionExtension_Depth: 24,
            kCMFormatDescriptionExtension_FullRangeVideo: isFullRange,
            kCMFormatDescriptionExtension_FieldCount: 1,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": av1CodecConfiguration],
            "BitsPerComponent" as CFString: bitDepth,
        ]

        switch colorPrimaries {
        case 1: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 6: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_SMPTE_C
        case 9: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        default: break
        }

        switch transferCharacteristics {
        case 1, 6: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 7: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_240M_1995
        case 8: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_Linear
        case 14, 15: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2020
        case 16: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 17: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: break
        }

        switch matrixCoefficients {
        case 1: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 6: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case 7: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        case 9: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: break
        }

        switch chromaSamplePosition {
        case 1: extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = kCMFormatDescriptionChromaLocation_Left
        case 2: extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = kCMFormatDescriptionChromaLocation_TopLeft
        default: break
        }

        return extensions
    }

    /// AV1CodecConfigurationRecord from the AV1 ISOBMFF binding.
    var av1CodecConfiguration: Data {
        var record = Data([
            0x81, // marker, version 1
            UInt8(profile << 5 | levelIndex),
            UInt8(tier << 7
                  | (bitDepth > 8 ? 1 : 0) << 6
                  | (bitDepth == 12 ? 1 : 0) << 5
                  | (isMonochrome ? 1 : 0) << 4
                  | subsamplingX << 3
                  | subsamplingY << 2
                  | chromaSamplePosition),
            0, // no initial presentation delay
        ])
        record.append(obu)
        return record
    }

    // MARK: - Parsing

    /// sequence_header_obu() from section 5.5 of the AV1 specification.
    private mutating func parse(_ payload: UnsafeBufferPointer<UInt8>) -> Bool {
        var reader = BitReader(payload)

        profile = reader.read(3)
        _ = reader.read(1) // still_picture
        let reducedStillPictureHeader = reader.readFlag()

        if reducedStillPictureHeader {
            levelIndex = reader.read(5)
        } else {
            var decoderModelInfoPresent = false
            var bufferDelayLength = 0
            if reader.readFlag() { // timing_info_present_flag
                reader.skip(32) // num_units_in_display_tick
                reader.skip(32) // time_scale
                if reader.readFlag() { // equal_picture_interval
                    reader.skipUVLC() // num_ticks_per_picture_minus_1
                }
                decoderModelInfoPresent = reader.readFlag()
                if decoderModelInfoPresent {
                    bufferDelayLength = reader.read(5) + 1
                    reader.skip(32) // num_units_in_decoding_tick
                    reader.skip(5) // buffer_removal_time_length_minus_1
                    reader.skip(5) // frame_presentation_time_length_minus_1
                }
            }
            let initialDisplayDelayPresent = reader.readFlag()
            let operatingPointCount = reader.read(5) + 1
            for index in 0..<operatingPointCount {
                reader.skip(12) // operating_point_idc
                let level = reader.read(5)
                let operatingTier = level > 7 ? reader.read(1) : 0
                if index == 0 {
                    levelIndex = level
                    tier = operatingTier
                }
                if decoderModelInfoPresent, reader.readFlag() { // decoder_model_present_for_this_op
                    reader.skip(bufferDelayLength) // decoder_buffer_delay
                    reader.skip(bufferDelayLength) // encoder_buffer_delay
                    reader.skip(1) // low_delay_mode_flag
                }
                if initialDisplayDelayPresent, reader.readFlag() { // initial_display_delay_present_for_this_op
                    reader.skip(4) // initial_display_delay_minus_1
                }
            }
        }

        let widthBits = reader.read(4) + 1
        let heightBits = reader.read(4) + 1
        maxFrameWidth = reader.read(widthBits) + 1
        maxFrameHeight = reader.read(heightBits) + 1

        if !reducedStillPictureHeader, reader.readFlag() { // frame_id_numbers_present_flag
            reader.skip(4) // delta_frame_id_length_minus_2
            reader.skip(3) // additional_frame_id_length_minus_1
        }
        reader.skip(1) // use_128x128_superblock
        reader.skip(1) // enable_filter_intra
        reader.skip(1) // enable_intra_edge_filter

        if !reducedStillPictureHeader {
            reader.skip(1) // enable_interintra_compound
            reader.skip(1) // enable_masked_compound
            reader.skip(1) // enable_warped_motion
            reader.skip(1) // enable_dual_filter
            let enableOrderHint = reader.readFlag()
            if enableOrderHint {
                reader.skip(1) // enable_jnt_comp
                reader.skip(1) // enable_ref_frame_mvs
            }
            // seq_force_screen_content_tools is SELECT_SCREEN_CONTENT_TOOLS when chosen
            let forceScreenContentTools = reader.readFlag() ? 2 : reader.read(1)
            if forceScreenContentTools > 0, !reader.readFlag() { // seq_choose_integer_mv
                reader.skip(1) // seq_force_integer_mv
            }
            if enableOrderHint {
                reader.skip(3) // order_hint_bits_minus_1
            }
        }

        reader.skip(1) // enable_superres
        reader.skip(1) // enable_cdef
        reader.skip(1) // enable_restoration
        parseColorConfig(&reader)

        return !reader.isOverrun && maxFrameWidth > 0 && maxFrameHeight > 0
    }

    /// color_config() from section 5.5.2.
    private mutating func parseColorConfig(_ reader: inout BitReader) {
        let highBitDepth = reader.readFlag()
        if profile == 2, highBitDepth {
            bitDepth = reader.readFlag() ? 12 : 10
        } else {
            bitDepth = highBitDepth ? 10 : 8
        }

        isMonochrome = profile == 1 ? false : reader.readFlag()

        if reader.readFlag() { // color_description_present_flag
            colorPrimaries = reader.read(8)
            transferCharacteristics = reader.read(8)
            matrixCoefficients = reader.read(8)
        }

        if isMonochrome {
            isFullRange = reader.readFlag()
            subsamplingX = 1
            subsamplingY = 1
            chromaSamplePosition = 0
            return
        }

        // BT.709 primaries with sRGB transfer and the identity matrix is RGB
        if colorPrimaries == 1, transferCharacteristics == 13, matrixCoefficients == 0 {
            isFullRange = true
            subsamplingX = 0
            subsamplingY = 0
        } else {
            isFullRange = reader.readFlag()
            switch profile {
            case 0:
                subsamplingX = 1
                subsamplingY = 1
            case 1:
                subsamplingX = 0
                subsamplingY = 0
            default:
                if bitDepth == 12 {
                    subsamplingX = reader.read(1)
                    subsamplingY = subsamplingX == 1 ? reader.read(1) : 0
                } else {
                    subsamplingX = 1
                    subsamplingY = 0
                }
            }
            if subsamplingX == 1, subsamplingY == 1 {
                chromaSamplePosition = reader.read(2)
            }
        }
    }

    private static func readLEB128(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> (Int, Int)? {
        var value = 0
        for index in 0..<8 {
            guard offset + index < bytes.count else { return nil }
            let byte = bytes[offset + index]
            value |= Int(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 {
                return (value, index + 1)
            }
        }
        return nil
    }

    private static func leb128(_ value: Int) -> Data {
        var value = value
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while value != 0
        return data
    }
}

/// MSB-first bit reader. Reads past the end yield zeros and set `isOverrun`.
nonisolated private struct BitReader {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var bitOffset = 0
    private(set) var isOverrun = false

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byteIndex = bitOffset / 8
            var bit = 0
            if byteIndex < bytes.count {
                bit = Int(bytes[byteIndex] >> (7 - UInt8(bitOffset % 8))) & 1
            } else {
                isOverrun = true
            }
            value = value << 1 | bit
            bitOffset += 1
        }
        return value
    }

    mutating func readFlag() -> Bool {
        read(1) == 1
    }

    mutating func skip(_ count: Int) {
        _ = read(count)
    }

    /// uvlc() from section 4.10.3.
    mutating func skipUVLC() {
        var leadingZeros = 0
        while !isOverrun, !readFlag() {
            leadingZeros += 1
        }
        if leadingZeros < 32 {
            skip(leadingZeros)
        }
    }
}
