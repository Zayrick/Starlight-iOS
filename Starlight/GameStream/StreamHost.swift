//
//  StreamHost.swift
//  Starlight
//

import Foundation

nonisolated struct StreamHost: Identifiable, Codable, Hashable, Sendable {
    enum Status: Hashable {
        case unknown
        case online
        case offline
    }

    enum PairState: Hashable {
        case unknown
        case paired
        case unpaired
    }

    /// The host's `uniqueid`.
    let id: String
    var name: String
    var localAddress: HostAddress?
    var manualAddress: HostAddress?
    var externalAddress: HostAddress?
    var ipv6Address: HostAddress?
    var httpsPort: UInt16 = HostAddress.defaultHTTPSPort
    var macAddress: String?
    var appVersion: String?
    var gpuType: String?
    /// DER certificate pinned when pairing succeeded. This is only a credential
    /// for connecting; whether we're still paired is decided by the host.
    var serverCertificate: Data?
    var apps: [StreamApp] = []

    // Runtime state, not persisted
    var status: Status = .unknown
    var pairState: PairState = .unknown
    var activeAddress: HostAddress?
    var currentGameID: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, localAddress, manualAddress, externalAddress, ipv6Address
        case httpsPort, macAddress, appVersion, gpuType, serverCertificate, apps
    }

    /// A copy with the runtime state reset, so it compares equal exactly when
    /// the persisted fields do.
    var persistentState: StreamHost {
        var host = self
        host.status = .unknown
        host.pairState = .unknown
        host.activeAddress = nil
        host.currentGameID = nil
        return host
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var isOnline: Bool { status == .online }
    var isPaired: Bool { pairState == .paired }
    /// Reachable and the handshake has told us whether we're paired.
    var isConnected: Bool { isOnline && pairState != .unknown }

    /// Addresses to try, most likely to succeed first, without duplicates.
    var candidateAddresses: [HostAddress] {
        var seen = Set<HostAddress>()
        return [activeAddress, localAddress, manualAddress, externalAddress, ipv6Address]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    var displayAddress: HostAddress? {
        activeAddress ?? localAddress ?? manualAddress ?? externalAddress ?? ipv6Address
    }

    func client(at address: HostAddress) -> GameStreamClient {
        GameStreamClient(address: address, httpsPort: httpsPort, serverCertificate: serverCertificate)
    }

    /// Merges a `/serverinfo` response that was obtained via `address`.
    mutating func apply(_ info: ServerInfo, reachedAt address: HostAddress) {
        name = info.name
        httpsPort = info.httpsPort
        appVersion = info.appVersion
        gpuType = info.gpuType
        currentGameID = info.currentGameID
        if let mac = info.macAddress {
            macAddress = mac
        }

        if let localIP = info.localIP, !localIP.hasPrefix("127.") {
            // Keep the port we reached the host on if it's the same interface
            let port = address.host == localIP
                ? address.port
                : localAddress?.port ?? HostAddress.defaultHTTPPort
            localAddress = HostAddress(host: localIP, port: port)
        }
        if let externalIP = info.externalIP, !externalIP.isEmpty {
            externalAddress = HostAddress(
                host: externalIP,
                port: info.externalPort ?? address.port
            )
        }
        if address.isIPv6 {
            ipv6Address = address
        }

        activeAddress = address
        status = .online
        if let isPaired = info.isPaired {
            pairState = isPaired ? .paired : .unpaired
        }
    }
}
