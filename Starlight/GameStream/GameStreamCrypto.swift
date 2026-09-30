//
//  GameStreamCrypto.swift
//  Starlight
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

nonisolated enum GameStreamCrypto {
    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return bytes
    }

    /// Gen 7+ servers (all Sunshine versions) use SHA-256, older GFE uses SHA-1.
    static func hash(_ data: Data, useSHA256: Bool) -> Data {
        useSHA256
            ? Data(SHA256.hash(data: data))
            : Data(Insecure.SHA1.hash(data: data))
    }

    static func aesEncrypt(_ data: Data, key: Data) throws -> Data {
        try aesECB(CCOperation(kCCEncrypt), data, key: key)
    }

    static func aesDecrypt(_ data: Data, key: Data) throws -> Data {
        try aesECB(CCOperation(kCCDecrypt), data, key: key)
    }

    /// AES-128-ECB without padding, matching the GameStream pairing protocol.
    private static func aesECB(_ operation: CCOperation, _ data: Data, key: Data) throws -> Data {
        var output = Data(count: data.count)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress, key.count,
                        nil,
                        dataBuffer.baseAddress, data.count,
                        outputBuffer.baseAddress, data.count,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw GameStreamError.crypto("AES 运算失败 (\(status))")
        }
        return output.prefix(outputLength)
    }

    static func verify(_ data: Data, signature: Data, certificateDER: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else {
            return false
        }
        return SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            signature as CFData,
            nil
        )
    }

    /// Extracts the signatureValue BIT STRING from a DER encoded X.509 certificate.
    static func certificateSignature(_ certificateDER: Data) -> Data? {
        guard let outer = DER.elements(in: certificateDER)?.first, outer.tag == 0x30,
              let parts = DER.elements(in: outer.content), parts.count == 3,
              parts[2].tag == 0x03, !parts[2].content.isEmpty else {
            return nil
        }
        // Drop the "unused bits" prefix byte
        return parts[2].content.dropFirst()
    }

    static func pem(fromDER der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    static func der(fromPEM pem: String) -> Data? {
        let base64 = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }
}

nonisolated extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(decoding: characters[index...index + 1], as: UTF8.self), radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        self = data
    }
}
