//
//  HostStore.swift
//  Starlight
//
//  Owns the list of GameStream hosts: mDNS discovery, manual additions,
//  periodic status polling, pairing and app list retrieval.
//

import Foundation
import ImageIO
import Observation

@Observable
final class HostStore {
    struct Pairing: Equatable {
        let hostID: String
        let pin: String
        var errorMessage: String?
    }

    enum AppListState: Equatable {
        case loading
        case failed(String)
    }

    private(set) var hosts: [StreamHost] = []
    private(set) var pairing: Pairing?
    private(set) var appListStates: [String: AppListState] = [:]

    @ObservationIgnored private let discovery = HostDiscovery()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    /// Hosts excluded from polling while a pairing or app list request is running.
    @ObservationIgnored private var busyHostIDs: Set<String> = []
    @ObservationIgnored private var probingAddresses: Set<HostAddress> = []
    /// Box art of connected hosts, shared by every view showing it. Only kept
    /// while the host stays connected so it's fetched again after each handshake.
    @ObservationIgnored private var artworkImages: [ArtworkKey: CGImage] = [:]
    @ObservationIgnored private var artworkLoads: [ArtworkKey: Task<CGImage?, Never>] = [:]

    private static let pollInterval: Duration = .seconds(3)

    init() {
        // Status and pair state are runtime only: they start unknown and are
        // determined by the first real handshake with each host
        hosts = Self.loadHosts()
        discovery.onResolve = { [weak self] address in
            self?.probeDiscoveredAddress(address)
        }
    }

    func host(id: String) -> StreamHost? {
        hosts.first { $0.id == id }
    }

    // MARK: - Discovery & polling

    func start() {
        discovery.start()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAllHosts()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        discovery.stop()
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollAllHosts() async {
        let ids = hosts.map(\.id).filter { !busyHostIDs.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.poll(hostID: id) }
            }
        }
    }

    private func poll(hostID: String) async {
        guard let host = host(id: hostID) else { return }

        // Give known hosts two rounds before declaring them offline
        let rounds = host.status == .unknown ? 1 : 2
        for _ in 0..<rounds {
            for address in host.candidateAddresses {
                guard !Task.isCancelled, !busyHostIDs.contains(hostID) else { return }
                guard let info = try? await host.client(at: address).serverInfo(timeout: 3),
                      info.uuid == hostID else {
                    continue
                }
                update(hostID) { $0.apply(info, reachedAt: address) }
                return
            }
        }

        guard !Task.isCancelled, !busyHostIDs.contains(hostID) else { return }
        update(hostID) {
            $0.status = .offline
            // Must be confirmed again by the next successful handshake
            $0.pairState = .unknown
        }
    }

    private func probeDiscoveredAddress(_ address: HostAddress) {
        guard probingAddresses.insert(address).inserted else { return }
        Task {
            defer { probingAddresses.remove(address) }
            guard let info = try? await GameStreamClient(address: address).serverInfo() else {
                return
            }
            merge(info, reachedAt: address, isManual: false)
        }
    }

    /// Adds a host by IP address or hostname, returning its ID.
    @discardableResult
    func addHost(_ input: String) async throws -> String {
        guard let address = HostAddress(parsing: input) else {
            throw GameStreamError.invalidAddress
        }

        let info: ServerInfo
        do {
            info = try await GameStreamClient(address: address).serverInfo(timeout: 8)
        } catch let error as GameStreamError {
            throw error
        } catch {
            throw GameStreamError.unreachable(error.localizedDescription)
        }

        merge(info, reachedAt: address, isManual: true)
        return info.uuid
    }

    private func merge(_ info: ServerInfo, reachedAt address: HostAddress, isManual: Bool) {
        var info = info
        let index = hosts.firstIndex { $0.id == info.uuid } ?? {
            hosts.append(StreamHost(id: info.uuid, name: info.name))
            return hosts.endIndex - 1
        }()
        if hosts[index].serverCertificate != nil {
            // A plain HTTP probe can't tell whether we're paired; polling over HTTPS will
            info.isPaired = nil
        }
        hosts[index].apply(info, reachedAt: address)
        if isManual {
            hosts[index].manualAddress = address
        }
        saveHosts()
    }

    func removeHost(id: String) {
        if pairing?.hostID == id {
            cancelPairing()
        }
        hosts.removeAll { $0.id == id }
        appListStates[id] = nil
        discardArtwork(hostID: id)
        saveHosts()
    }

    private func update(_ hostID: String, _ body: (inout StreamHost) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        let previous = hosts[index].persistentState
        let wasConnected = hosts[index].isOnline && hosts[index].isPaired
        body(&hosts[index])
        if wasConnected, !(hosts[index].isOnline && hosts[index].isPaired) {
            discardArtwork(hostID: hostID)
        }
        if hosts[index].persistentState != previous {
            saveHosts()
        }
    }

    // MARK: - Pairing

    func startPairing(hostID: String) {
        guard let host = host(id: hostID) else { return }

        pairingTask?.cancel()
        let pin = PairingSession.generatePIN()
        pairing = Pairing(hostID: hostID, pin: pin)

        guard let address = host.displayAddress else {
            pairing?.errorMessage = String(localized: "No host address is available.")
            return
        }

        busyHostIDs.insert(hostID)
        pairingTask = Task {
            defer { busyHostIDs.remove(hostID) }
            do {
                let client = GameStreamClient(address: address, httpsPort: host.httpsPort)
                let info = try await client.serverInfo()
                guard info.uuid == hostID else {
                    throw GameStreamError.pairing(String(localized: "The host at this address has changed."))
                }

                let certificate = try await PairingSession(
                    client: GameStreamClient(address: address, httpsPort: info.httpsPort),
                    pin: pin,
                    serverMajorVersion: info.serverMajorVersion,
                    isServerBusy: info.isBusy
                ).run()

                update(hostID) {
                    $0.serverCertificate = certificate
                    $0.pairState = .paired
                    $0.httpsPort = info.httpsPort
                }
                pairing = nil
                pairingTask = nil
                await refreshApps(hostID: hostID)
            } catch is CancellationError {
                // cancelPairing() already reset the state
            } catch {
                guard !Task.isCancelled else { return }
                pairing?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = nil
    }

    // MARK: - Apps

    func refreshApps(hostID: String) async {
        guard let host = host(id: hostID), appListStates[hostID] != .loading else { return }
        guard host.serverCertificate != nil, let address = host.displayAddress else {
            appListStates[hostID] = .failed(GameStreamError.notPaired.localizedDescription)
            return
        }

        appListStates[hostID] = .loading
        busyHostIDs.insert(hostID)
        defer { busyHostIDs.remove(hostID) }

        var lastError: Error = GameStreamError.malformedResponse
        for attempt in 0..<3 {
            do {
                let apps = try await host.client(at: address).appList()
                update(hostID) {
                    $0.apps = apps
                    $0.status = .online
                }
                appListStates[hostID] = nil
                return
            } catch {
                lastError = error
                if case GameStreamError.server(code: 401, _) = error {
                    update(hostID) { $0.pairState = .unpaired }
                    break
                }
                guard !Task.isCancelled, attempt < 2 else { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        appListStates[hostID] = .failed(lastError.localizedDescription)
    }

    /// Quits the app running on a host.
    func quitApp(hostID: String) async throws {
        guard let host = host(id: hostID), let address = host.displayAddress else {
            throw GameStreamError.unreachable(String(localized: "No host address is available."))
        }
        try await host.client(at: address).quitApp()
        update(hostID) { $0.currentGameID = nil }
    }

    // MARK: - Artwork

    private struct ArtworkKey: Hashable {
        let hostID: String
        let appID: String
    }

    /// Decoded, downsampled box art of a connected host. Concurrent requests
    /// for the same app share one load.
    func artwork(for app: StreamApp, hostID: String) async -> CGImage? {
        let key = ArtworkKey(hostID: hostID, appID: app.id)
        if let image = artworkImages[key] {
            return image
        }
        if let load = artworkLoads[key] {
            return await load.value
        }
        guard let host = host(id: hostID), host.isOnline, host.isPaired,
              let address = host.displayAddress else {
            return nil
        }

        let client = host.client(at: address)
        let load = Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = try? await client.appAsset(appID: app.id) else { return nil }
            return Self.thumbnail(from: data, maxPixelSize: 600)
        }
        artworkLoads[key] = load
        let image = await load.value
        // Dropped if the host disconnected meanwhile and the load was discarded
        guard artworkLoads[key] == load else { return nil }
        artworkLoads[key] = nil
        artworkImages[key] = image
        return image
    }

    private func discardArtwork(hostID: String) {
        artworkImages = artworkImages.filter { $0.key.hostID != hostID }
        artworkLoads = artworkLoads.filter { $0.key.hostID != hostID }
    }

    nonisolated private static func thumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Persistence

    private static var hostsFile: URL {
        URL.applicationSupportDirectory
            .appending(path: "GameStream", directoryHint: .isDirectory)
            .appending(path: "hosts.json")
    }

    private static func loadHosts() -> [StreamHost] {
        guard let data = try? Data(contentsOf: hostsFile) else { return [] }
        return (try? JSONDecoder().decode([StreamHost].self, from: data)) ?? []
    }

    private func saveHosts() {
        let file = Self.hostsFile
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(hosts).write(to: file, options: .atomic)
        } catch {
            print("Failed to save hosts: \(error)")
        }
    }
}
