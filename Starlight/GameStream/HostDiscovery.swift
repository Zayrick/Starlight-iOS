//
//  HostDiscovery.swift
//  Starlight
//
//  Browses the local network for `_nvstream._tcp` services and resolves them
//  to concrete IP addresses.
//

import Foundation
import Network

final class HostDiscovery {
    private static let serviceType = "_nvstream._tcp"

    var onResolve: ((HostAddress) -> Void)?

    private var browser: NWBrowser?
    private var resolvers: [NWEndpoint: NWConnection] = [:]
    private var restartTask: Task<Void, Never>?

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )

        browser.browseResultsChangedHandler = { [weak self] _, changes in
            MainActor.assumeIsolated {
                for change in changes {
                    switch change {
                    case .added(let result):
                        self?.resolve(result.endpoint)
                    case .changed(_, let result, _):
                        self?.resolve(result.endpoint)
                    default:
                        break
                    }
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state {
                    self?.scheduleRestart()
                }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
    }

    /// Browsing can fail when the network changes, so try again shortly.
    private func scheduleRestart() {
        stop()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// Opens a short-lived TCP connection to learn the service's IP address.
    /// IPv4 is preferred because link-local IPv6 addresses are awkward in URLs.
    private func resolve(_ endpoint: NWEndpoint, preferIPv4: Bool = true) {
        guard resolvers[endpoint] == nil else { return }

        let parameters = NWParameters.tcp
        if preferIPv4, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        resolvers[endpoint] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        self.onResolve?(HostAddress(host: host.addressString, port: port.rawValue))
                    }
                    self.finishResolving(endpoint)
                case .failed, .waiting:
                    self.finishResolving(endpoint)
                    if preferIPv4 {
                        self.resolve(endpoint, preferIPv4: false)
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)

        // Don't let an unresponsive service hold a resolver forever
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.resolvers[endpoint] === connection {
                self?.finishResolving(endpoint)
            }
        }
    }

    private func finishResolving(_ endpoint: NWEndpoint) {
        resolvers.removeValue(forKey: endpoint)?.cancel()
    }
}

private extension NWEndpoint.Host {
    /// String form of the address. The description includes the interface scope
    /// (`192.168.1.2%en0`), which is only meaningful for link-local IPv6.
    var addressString: String {
        switch self {
        case .ipv4(let address):
            Self.removingScope("\(address)")
        case .ipv6(let address):
            address.isLinkLocal ? "\(address)" : Self.removingScope("\(address)")
        case .name(let name, _):
            name
        @unknown default:
            "\(self)"
        }
    }

    private static func removingScope(_ address: String) -> String {
        String(address.prefix { $0 != "%" })
    }
}
