//
//  GameStreamModels.swift
//  Starlight
//

import Foundation

nonisolated enum GameStreamError: LocalizedError {
    case invalidAddress
    case unreachable(String)
    case server(code: Int, message: String)
    case malformedResponse
    case notPaired
    case pairing(String)
    case crypto(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "地址格式无效"
        case .unreachable(let message):
            "无法连接到主机：\(message)"
        case .server(let code, let message):
            "主机返回错误 \(code)：\(message)"
        case .malformedResponse:
            "主机返回了无法解析的数据"
        case .notPaired:
            "尚未与此主机配对"
        case .pairing(let message):
            message
        case .crypto(let message):
            message
        }
    }
}

/// An address and HTTP port pair used to reach a host.
nonisolated struct HostAddress: Codable, Hashable, Sendable, CustomStringConvertible {
    static let defaultHTTPPort: UInt16 = 47989
    static let defaultHTTPSPort: UInt16 = 47984

    var host: String
    var port: UInt16

    init(host: String, port: UInt16 = HostAddress.defaultHTTPPort) {
        self.host = host
        self.port = port
    }

    /// Parses user input such as `192.168.1.2`, `pc.local:47989`, `fe80::1` or `[fe80::1]:47989`.
    init?(parsing input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty {
                self.init(host: host)
            } else if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) {
                self.init(host: host, port: port)
            } else {
                return nil
            }
        } else if text.filter({ $0 == ":" }).count == 1 {
            let parts = text.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
            self.init(host: String(parts[0]), port: port)
        } else {
            // Hostname, IPv4 or bare IPv6 literal
            self.init(host: text)
        }
    }

    var isIPv6: Bool { host.contains(":") }

    /// Host component suitable for embedding in a URL.
    var urlHost: String {
        isIPv6
            ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
            : host
    }

    func httpURL(_ path: String) -> URL? {
        URL(string: "http://\(urlHost):\(port)\(path)")
    }

    func httpsURL(port httpsPort: UInt16, _ path: String) -> URL? {
        URL(string: "https://\(urlHost):\(httpsPort)\(path)")
    }

    var description: String {
        let displayHost = isIPv6 ? "[\(host)]" : host
        return port == Self.defaultHTTPPort ? displayHost : "\(displayHost):\(port)"
    }
}

nonisolated struct StreamApp: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var isHDRSupported: Bool
}

/// Parsed `/serverinfo` response.
nonisolated struct ServerInfo: Sendable {
    var name: String
    var uuid: String
    var macAddress: String?
    var appVersion: String?
    var gfeVersion: String?
    /// Bitmask of the `SCM_*` codecs the host can encode.
    var serverCodecModeSupport: Int
    var gpuType: String?
    var localIP: String?
    var externalIP: String?
    var externalPort: UInt16?
    var httpsPort: UInt16
    var isPaired: Bool?
    var currentGameID: String?
    var state: String?

    init(xml: XMLTree) throws {
        guard let uuid = xml.text("uniqueid"), !uuid.isEmpty else {
            throw GameStreamError.malformedResponse
        }
        self.uuid = uuid
        name = xml.text("hostname") ?? "未知主机"
        let mac = xml.text("mac")
        macAddress = mac == "00:00:00:00:00:00" ? nil : mac
        appVersion = xml.text("appversion")
        gfeVersion = xml.text("GfeVersion")
        serverCodecModeSupport = xml.text("ServerCodecModeSupport").flatMap { Int($0) } ?? 0
        gpuType = xml.text("gputype")
        localIP = xml.text("LocalIP")
        externalIP = xml.text("ExternalIP")
        externalPort = xml.text("ExternalPort").flatMap { UInt16($0) }
        httpsPort = xml.text("HttpsPort").flatMap { UInt16($0) } ?? HostAddress.defaultHTTPSPort
        isPaired = xml.text("PairStatus").map { $0 == "1" }
        state = xml.text("state")
        // GFE keeps currentgame set after a session ends, so only trust it while busy
        let game = xml.text("currentgame")
        currentGameID = isBusy && game != "0" ? game : nil
    }

    var isBusy: Bool {
        state?.hasSuffix("_SERVER_BUSY") == true
    }

    var serverMajorVersion: Int {
        appVersion?.split(separator: ".").first.flatMap { Int($0) } ?? 7
    }

    /// Sunshine reports a negative build number in `appversion`, e.g. `7.1.431.-1`.
    var isSunshine: Bool {
        appVersion?.contains(".-") == true
    }
}

/// Parameters of a `/launch` or `/resume` request.
nonisolated struct LaunchRequest: Sendable {
    var appID: String
    var width: Int
    var height: Int
    var fps: Int
    /// AES key and key ID protecting the input and audio streams.
    var remoteInputKey: Data
    var remoteInputKeyID: UInt32
    var hdr: Bool
    var surroundAudioInfo: Int
    /// Lets the host adjust game settings to match the stream.
    var optimizeGameSettings: Bool
    var playAudioOnHost: Bool
    /// Extra `&key=value` pairs required by moonlight-common-c.
    var extraQuery: String = ""
}
