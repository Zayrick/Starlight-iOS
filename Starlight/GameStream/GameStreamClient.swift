//
//  GameStreamClient.swift
//  Starlight
//
//  HTTP(S) API of a GameStream host (Sunshine / GeForce Experience).
//

import Foundation
import Security

nonisolated struct GameStreamClient: Sendable {
    /// Moonlight clients share this ID so they can quit each other's sessions.
    static let uniqueID = "0123456789ABCDEF"
    static let deviceName = "Starlight"

    let address: HostAddress
    let httpsPort: UInt16
    /// DER certificate of the server, pinned during pairing.
    var serverCertificate: Data?

    init(address: HostAddress, httpsPort: UInt16 = HostAddress.defaultHTTPSPort, serverCertificate: Data? = nil) {
        self.address = address
        self.httpsPort = httpsPort
        self.serverCertificate = serverCertificate
    }

    // MARK: - Endpoints

    /// Queries `/serverinfo`, over HTTPS when a certificate is pinned so that the
    /// host reports our real pair status, falling back to plain HTTP otherwise.
    func serverInfo(timeout: TimeInterval = 5) async throws -> ServerInfo {
        if serverCertificate != nil {
            do {
                return try ServerInfo(xml: await request(secure: true, "/serverinfo", timeout: timeout))
            } catch GameStreamError.server(code: 401, _) {
                // The host no longer trusts our certificate
            } catch let error as URLError where error.code.isCertificateFailure {
                // The host certificate changed, e.g. after a reinstall
            }
        }

        var info = try ServerInfo(xml: await request(secure: false, "/serverinfo", timeout: timeout))
        if serverCertificate != nil {
            // Plain HTTP responses never report a paired state
            info.isPaired = false
        }
        return info
    }

    func appList() async throws -> [StreamApp] {
        let xml = try await request(secure: true, "/applist", timeout: 10)
        return xml.children("App").compactMap { app in
            guard let id = app.text("ID") else { return nil }
            return StreamApp(
                id: id,
                name: app.text("AppTitle") ?? "",
                isHDRSupported: app.text("IsHdrSupported") == "1"
            )
        }
    }

    /// Box art PNG for an app.
    func appAsset(appID: String) async throws -> Data {
        let query = [
            URLQueryItem(name: "appid", value: appID),
            URLQueryItem(name: "AssetType", value: "2"),
            URLQueryItem(name: "AssetIdx", value: "0")
        ]
        let data = try await rawRequest(secure: true, "/appasset", query: query, timeout: 10)
        guard !data.isEmpty else { throw GameStreamError.malformedResponse }
        return data
    }

    /// Starts an app, or reconnects to the running one when `resume` is set,
    /// and returns the RTSP session URL if the host provided one.
    func launch(_ launch: LaunchRequest, resume: Bool, server: ServerInfo) async throws -> String? {
        // GFE falls back to 720p60 for frame rates over 60, while 0 keeps the
        // requested resolution. Sunshine handles any frame rate.
        let fps = launch.fps > 60 && !server.isSunshine ? 0 : launch.fps

        var query = [
            URLQueryItem(name: "appid", value: launch.appID),
            URLQueryItem(name: "mode", value: "\(launch.width)x\(launch.height)x\(fps)"),
            URLQueryItem(name: "additionalStates", value: "1"),
            URLQueryItem(name: "sops", value: launch.optimizeGameSettings ? "1" : "0"),
            URLQueryItem(name: "rikey", value: launch.remoteInputKey.hexString),
            URLQueryItem(name: "rikeyid", value: String(Int32(bitPattern: launch.remoteInputKeyID))),
        ]
        if launch.hdr {
            query += [
                URLQueryItem(name: "hdrMode", value: "1"),
                URLQueryItem(name: "clientHdrCapVersion", value: "0"),
                URLQueryItem(name: "clientHdrCapSupportedFlagsInUint32", value: "0"),
                URLQueryItem(name: "clientHdrCapMetaDataId", value: "NV_STATIC_METADATA_TYPE_1"),
                URLQueryItem(name: "clientHdrCapDisplayData", value: "0x0x0x0x0x0x0x0x0x0x0"),
            ]
        }
        query += [
            URLQueryItem(name: "localAudioPlayMode", value: launch.playAudioOnHost ? "1" : "0"),
            URLQueryItem(name: "surroundAudioInfo", value: String(launch.surroundAudioInfo)),
            // No controllers are forwarded yet
            URLQueryItem(name: "remoteControllersBitmap", value: "0"),
            URLQueryItem(name: "gcmap", value: "0"),
            URLQueryItem(name: "gcpersist", value: "0"),
        ]
        query += launch.extraQuery
            .split(separator: "&")
            .map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                return URLQueryItem(name: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : nil)
            }

        // This blocks while the host starts the app
        let xml = try await request(secure: true, resume ? "/resume" : "/launch", query: query, timeout: 120)
        let succeeded = resume
            ? xml.text("resume").map { $0 != "0" } ?? false
            : xml.text("gamesession").map { $0 != "0" } ?? false
        guard succeeded else {
            throw GameStreamError.server(code: 0, message: resume ? "无法恢复应用" : "无法启动应用")
        }
        return xml.text("sessionUrl0").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Quits the app running on the host.
    func quitApp() async throws {
        let xml = try await request(secure: true, "/cancel", timeout: 30)
        // GFE reports success but keeps running apps started by another client
        if xml.text("cancel") == "0" {
            throw GameStreamError.server(code: 0, message: "主机拒绝退出应用")
        }
    }

    func pair(_ query: [URLQueryItem], secure: Bool = false, timeout: TimeInterval = 10) async throws -> XMLTree {
        let base = [
            URLQueryItem(name: "devicename", value: Self.deviceName),
            URLQueryItem(name: "updateState", value: "1")
        ]
        return try await request(secure: secure, "/pair", query: base + query, timeout: timeout)
    }

    func unpair() async {
        _ = try? await rawRequest(secure: false, "/unpair", timeout: 5)
    }

    // MARK: - Transport

    private func request(
        secure: Bool,
        _ path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval
    ) async throws -> XMLTree {
        let data = try await rawRequest(secure: secure, path, query: query, timeout: timeout)
        guard let root = XMLTree.parse(data) else {
            throw GameStreamError.malformedResponse
        }

        let code = root.attributes["status_code"].flatMap { Int($0) } ?? 0
        guard code == 200 else {
            throw GameStreamError.server(
                code: code,
                message: root.attributes["status_message"] ?? "未知错误"
            )
        }
        return root
    }

    private func rawRequest(
        secure: Bool,
        _ path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval
    ) async throws -> Data {
        let baseURL = secure
            ? address.httpsURL(port: httpsPort, path)
            : address.httpURL(path)
        guard let baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GameStreamError.invalidAddress
        }
        components.queryItems = [URLQueryItem(name: "uniqueid", value: Self.uniqueID)] + query
        guard let url = components.url else {
            throw GameStreamError.invalidAddress
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"

        let delegate: TLSDelegate?
        if secure {
            guard let serverCertificate else { throw GameStreamError.notPaired }
            delegate = TLSDelegate(
                pinnedCertificate: serverCertificate,
                identity: try ClientIdentity.shared().identity
            )
        } else {
            delegate = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, _) = try await session.data(for: request)
        return data
    }
}

/// Pins the host certificate and presents our client certificate.
nonisolated private final class TLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pinnedCertificate: Data
    let identity: SecIdentity

    init(pinnedCertificate: Data, identity: SecIdentity) {
        self.pinnedCertificate = pinnedCertificate
        self.identity = identity
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  SecCertificateCopyData(leaf) as Data == pinnedCertificate else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))

        case NSURLAuthenticationMethodClientCertificate:
            return (
                .useCredential,
                URLCredential(identity: identity, certificates: nil, persistence: .forSession)
            )

        default:
            return (.performDefaultHandling, nil)
        }
    }
}

nonisolated private extension URLError.Code {
    var isCertificateFailure: Bool {
        switch self {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .secureConnectionFailed, .cancelled:
            true
        default:
            false
        }
    }
}
