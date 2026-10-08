//
//  PairingSession.swift
//  Starlight
//
//  GameStream PIN pairing, ported from Moonlight's PairManager.
//

import Foundation

nonisolated struct PairingSession {
    let client: GameStreamClient
    let pin: String
    let serverMajorVersion: Int
    let isServerBusy: Bool

    static func generatePIN() -> String {
        (0..<4).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// Runs the full handshake and returns the pinned server certificate (DER).
    func run() async throws -> Data {
        do {
            return try await handshake()
        } catch {
            // Leave the host in a clean state if any stage failed. This runs in an
            // unstructured task so it still goes out when pairing was cancelled.
            let client = client
            Task { await client.unpair() }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func handshake() async throws -> Data {
        let identity = try ClientIdentity.shared()
        let useSHA256 = serverMajorVersion >= 7
        let hashLength = useSHA256 ? 32 : 20

        // Stage 1: send salt + client certificate, wait for the user to enter the PIN on the host
        let salt = GameStreamCrypto.randomBytes(16)
        let getCertResponse = try await stage(
            [
                URLQueryItem(name: "phrase", value: "getservercert"),
                URLQueryItem(name: "salt", value: salt.hexString),
                URLQueryItem(name: "clientcert", value: identity.certificatePEM.hexString)
            ],
            timeout: 600,
            failure: isServerBusy
                ? String(localized: "A stream is still running on the host. End it before pairing.")
                : String(localized: "The host declined the pairing request.")
        )

        guard let plainCert = getCertResponse.text("plaincert"), !plainCert.isEmpty,
              let certPEM = Data(hexString: plainCert).flatMap({ String(data: $0, encoding: .utf8) }),
              let serverCertificate = GameStreamCrypto.der(fromPEM: certPEM),
              let serverSignature = GameStreamCrypto.certificateSignature(serverCertificate) else {
            throw GameStreamError.pairing(String(localized: "Another pairing request is already in progress on the host."))
        }

        let aesKey = GameStreamCrypto.hash(salt + Data(pin.utf8), useSHA256: useSHA256).prefix(16)

        // Stage 2: client challenge
        let randomChallenge = GameStreamCrypto.randomBytes(16)
        let challengeResponse = try await stage(
            [URLQueryItem(
                name: "clientchallenge",
                value: try GameStreamCrypto.aesEncrypt(randomChallenge, key: aesKey).hexString
            )],
            failure: Self.stepFailure(2)
        )

        guard let encryptedServerResponse = challengeResponse.text("challengeresponse").flatMap(Data.init(hexString:)) else {
            throw GameStreamError.malformedResponse
        }
        let serverResponse = try GameStreamCrypto.aesDecrypt(encryptedServerResponse, key: aesKey)
        guard serverResponse.count >= hashLength + 16 else {
            throw GameStreamError.malformedResponse
        }
        let serverResponseHash = serverResponse.prefix(hashLength)
        let serverChallenge = serverResponse.dropFirst(hashLength).prefix(16)

        // Stage 3: answer the server challenge
        let clientSecret = GameStreamCrypto.randomBytes(16)
        var challengeResponseHash = GameStreamCrypto.hash(
            serverChallenge + identity.certificateSignature + clientSecret,
            useSHA256: useSHA256
        )
        challengeResponseHash.count = 32
        let secretResponse = try await stage(
            [URLQueryItem(
                name: "serverchallengeresp",
                value: try GameStreamCrypto.aesEncrypt(challengeResponseHash, key: aesKey).hexString
            )],
            failure: Self.stepFailure(3)
        )

        guard let pairingSecret = secretResponse.text("pairingsecret").flatMap(Data.init(hexString:)),
              pairingSecret.count > 16 else {
            throw GameStreamError.malformedResponse
        }
        let serverSecret = pairingSecret.prefix(16)
        let serverSecretSignature = pairingSecret.dropFirst(16)

        guard GameStreamCrypto.verify(
            Data(serverSecret),
            signature: Data(serverSecretSignature),
            certificateDER: serverCertificate
        ) else {
            throw GameStreamError.pairing(String(localized: "The host's certificate couldn't be verified. Someone may be intercepting the connection."))
        }

        // The server proves it knew the PIN by hashing our challenge
        let expectedServerHash = GameStreamCrypto.hash(
            randomChallenge + serverSignature + serverSecret,
            useSHA256: useSHA256
        )
        guard expectedServerHash == serverResponseHash else {
            throw GameStreamError.pairing(String(localized: "Incorrect PIN. Try again."))
        }

        // Stage 4: send our signed secret
        let clientPairingSecret = clientSecret + (try identity.sign(clientSecret))
        _ = try await stage(
            [URLQueryItem(name: "clientpairingsecret", value: clientPairingSecret.hexString)],
            failure: Self.stepFailure(4)
        )

        // Stage 5: confirm over HTTPS with the pinned certificate
        var secureClient = client
        secureClient.serverCertificate = serverCertificate
        let finalResponse = try await secureClient.pair(
            [URLQueryItem(name: "phrase", value: "pairchallenge")],
            secure: true
        )
        guard finalResponse.text("paired") == "1" else {
            throw GameStreamError.pairing(Self.stepFailure(5))
        }

        return serverCertificate
    }

    private static func stepFailure(_ step: Int) -> String {
        String(localized: "Pairing failed at step \(step).")
    }

    private func stage(
        _ query: [URLQueryItem],
        timeout: TimeInterval = 10,
        failure: String
    ) async throws -> XMLTree {
        let response: XMLTree
        do {
            response = try await client.pair(query, timeout: timeout)
        } catch GameStreamError.server(_, let message) {
            throw GameStreamError.pairing(String(localized: "\(failure) (\(message))", comment: "A pairing failure followed by the reason the host gave"))
        }
        guard response.text("paired") == "1" else {
            throw GameStreamError.pairing(failure)
        }
        return response
    }
}
