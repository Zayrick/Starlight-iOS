//
//  ClientIdentity.swift
//  Starlight
//
//  The RSA key pair and self-signed certificate that identify this client to
//  GameStream hosts. Both live in the keychain so that the system can vend a
//  SecIdentity for TLS client authentication.
//

import Foundation
import Security

nonisolated final class ClientIdentity: @unchecked Sendable {
    let privateKey: SecKey
    let certificateDER: Data
    let identity: SecIdentity

    private static let keyTag = Data("com.oxio.Starlight.client-key".utf8)
    private static let certificateLabel = "Starlight GameStream Client"
    private static let commonName = "NVIDIA GameStream Client"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: ClientIdentity?
    /// The data protection keychain needs signing entitlements on macOS; unsigned
    /// builds fall back to the legacy file-based keychain.
    nonisolated(unsafe) private static var usesDataProtectionKeychain = true

    private init(privateKey: SecKey, certificateDER: Data, identity: SecIdentity) {
        self.privateKey = privateKey
        self.certificateDER = certificateDER
        self.identity = identity
    }

    var certificatePEM: Data {
        Data(GameStreamCrypto.pem(fromDER: certificateDER).utf8)
    }

    var certificateSignature: Data {
        GameStreamCrypto.certificateSignature(certificateDER) ?? Data()
    }

    func sign(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) else {
            throw GameStreamError.crypto("签名失败：\(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return signature as Data
    }

    /// Loads the identity from the keychain, generating a new one on first use.
    static func shared() throws -> ClientIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let cached {
            return cached
        }
        let identity: ClientIdentity
        do {
            identity = try load() ?? generate()
        } catch {
#if os(macOS)
            usesDataProtectionKeychain = false
            identity = try load() ?? generate()
#else
            throw error
#endif
        }
        cached = identity
        return identity
    }

    // MARK: - Keychain

    private static func baseQuery(_ itemClass: CFString) -> [CFString: Any] {
        [
            kSecClass: itemClass,
            kSecUseDataProtectionKeychain: usesDataProtectionKeychain
        ]
    }

    private static func load() -> ClientIdentity? {
        var keyQuery = baseQuery(kSecClassKey)
        keyQuery[kSecAttrApplicationTag] = keyTag
        keyQuery[kSecAttrKeyType] = kSecAttrKeyTypeRSA
        keyQuery[kSecReturnRef] = true

        var certificateQuery = baseQuery(kSecClassCertificate)
        certificateQuery[kSecAttrLabel] = certificateLabel
        certificateQuery[kSecReturnRef] = true

        var keyRef: CFTypeRef?
        var certificateRef: CFTypeRef?
        guard SecItemCopyMatching(keyQuery as CFDictionary, &keyRef) == errSecSuccess,
              SecItemCopyMatching(certificateQuery as CFDictionary, &certificateRef) == errSecSuccess,
              let keyRef, let certificateRef else {
            return nil
        }

        let certificate = certificateRef as! SecCertificate
        let certificateDER = SecCertificateCopyData(certificate) as Data
        guard let identity = findIdentity(matching: certificateDER) else {
            return nil
        }
        return ClientIdentity(
            privateKey: keyRef as! SecKey,
            certificateDER: certificateDER,
            identity: identity
        )
    }

    private static func findIdentity(matching certificateDER: Data) -> SecIdentity? {
        var query = baseQuery(kSecClassIdentity)
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitAll

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else {
            return nil
        }

        return identities.first { identity in
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            return certificate.map { SecCertificateCopyData($0) as Data } == certificateDER
        }
    }

    private static func deleteStoredItems() {
        var keyQuery = baseQuery(kSecClassKey)
        keyQuery[kSecAttrApplicationTag] = keyTag
        SecItemDelete(keyQuery as CFDictionary)

        var certificateQuery = baseQuery(kSecClassCertificate)
        certificateQuery[kSecAttrLabel] = certificateLabel
        SecItemDelete(certificateQuery as CFDictionary)
    }

    private static func generate() throws -> ClientIdentity {
        deleteStoredItems()

        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecUseDataProtectionKeychain: usesDataProtectionKeychain,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: keyTag,
                kSecAttrLabel: certificateLabel
            ] as [CFString: Any]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw GameStreamError.crypto("生成密钥失败：\(error?.takeRetainedValue().localizedDescription ?? "")")
        }

        let certificateDER = try makeCertificate(publicKey: publicKeyData, privateKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw GameStreamError.crypto("生成的证书无效")
        }

        var addQuery = baseQuery(kSecClassCertificate)
        addQuery[kSecValueRef] = certificate
        addQuery[kSecAttrLabel] = certificateLabel
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw GameStreamError.crypto("无法保存证书到钥匙串 (\(status))")
        }

        guard let identity = findIdentity(matching: certificateDER) else {
            throw GameStreamError.crypto("无法从钥匙串读取客户端身份")
        }
        return ClientIdentity(
            privateKey: privateKey,
            certificateDER: certificateDER,
            identity: identity
        )
    }

    // MARK: - Certificate

    /// Builds a self-signed X.509 v3 certificate equivalent to Moonlight's `mkcert`.
    private static func makeCertificate(publicKey: Data, privateKey: SecKey) throws -> Data {
        let sha256WithRSA = DER.sequence(
            DER.objectIdentifier([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]),
            DER.null
        )
        let rsaEncryption = DER.sequence(
            DER.objectIdentifier([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]),
            DER.null
        )
        let name = DER.sequence(
            DER.set(
                DER.sequence(
                    DER.objectIdentifier([0x55, 0x04, 0x03]),
                    DER.utf8String(commonName)
                )
            )
        )

        let now = Date()
        let notAfter = Calendar(identifier: .gregorian)
            .date(byAdding: .year, value: 20, to: now) ?? now

        let tbsCertificate = DER.sequence(
            DER.explicit(0, DER.integer(2)),
            DER.integer(GameStreamCrypto.randomBytes(8)),
            sha256WithRSA,
            name,
            DER.sequence(DER.time(now), DER.time(notAfter)),
            name,
            DER.sequence(rsaEncryption, DER.bitString(publicKey))
        )

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCertificate as CFData,
            &error
        ) as Data? else {
            throw GameStreamError.crypto("证书签名失败：\(error?.takeRetainedValue().localizedDescription ?? "")")
        }

        return DER.sequence(tbsCertificate, sha256WithRSA, DER.bitString(signature))
    }
}
