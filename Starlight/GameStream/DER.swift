//
//  DER.swift
//  Starlight
//
//  Minimal ASN.1 DER encoder/decoder, just enough to build a self-signed
//  X.509 certificate and to extract the signature from a peer certificate.
//

import Foundation

nonisolated enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        data.append(length(content.count))
        data.append(content)
        return data
    }

    static func sequence(_ items: Data...) -> Data {
        tlv(0x30, items.reduce(into: Data()) { $0.append($1) })
    }

    static func set(_ items: Data...) -> Data {
        tlv(0x31, items.reduce(into: Data()) { $0.append($1) })
    }

    static func integer(_ bytes: Data) -> Data {
        var bytes = Data(bytes.drop { $0 == 0 })
        // INTEGER is signed, so prefix a zero byte when the high bit is set
        if bytes.isEmpty || bytes[bytes.startIndex] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tlv(0x02, bytes)
    }

    static func integer(_ value: Int) -> Data {
        var bigEndian = UInt64(value).bigEndian
        return integer(Data(bytes: &bigEndian, count: 8))
    }

    static func bitString(_ bytes: Data) -> Data {
        tlv(0x03, Data([0]) + bytes)
    }

    static func utf8String(_ string: String) -> Data {
        tlv(0x0C, Data(string.utf8))
    }

    static func objectIdentifier(_ encoded: [UInt8]) -> Data {
        tlv(0x06, Data(encoded))
    }

    static let null = Data([0x05, 0x00])

    static func explicit(_ tagNumber: UInt8, _ content: Data) -> Data {
        tlv(0xA0 | tagNumber, content)
    }

    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian)
            .dateComponents(in: formatter.timeZone, from: date).year ?? 2000
        // RFC 5280: UTCTime through 2049, GeneralizedTime afterwards
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        } else {
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return tlv(0x18, Data(formatter.string(from: date).utf8))
        }
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    // MARK: - Decoding

    struct Element {
        let tag: UInt8
        let content: Data
    }

    /// Parses the consecutive TLV elements contained in `data`.
    static func elements(in data: Data) -> [Element]? {
        var result: [Element] = []
        var index = data.startIndex
        while index < data.endIndex {
            let tag = data[index]
            index += 1
            guard index < data.endIndex else { return nil }

            var length = Int(data[index])
            index += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7F
                guard byteCount > 0, byteCount <= 4,
                      index + byteCount <= data.endIndex else { return nil }
                length = data[index..<index + byteCount]
                    .reduce(0) { ($0 << 8) | Int($1) }
                index += byteCount
            }

            guard index + length <= data.endIndex else { return nil }
            result.append(Element(tag: tag, content: Data(data[index..<index + length])))
            index += length
        }
        return result
    }
}
