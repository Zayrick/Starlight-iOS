//
//  DeviceDetailView.swift
//  Starlight
//

import SwiftUI

struct DeviceDetailView: View {
    let hostID: String

    @Environment(HostStore.self) private var hostStore

    private let columns = [
        GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 20)
    ]

    var body: some View {
        Group {
            if let host = hostStore.host(id: hostID) {
                content(for: host)
                    .navigationTitle(host.name)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            titleView(for: host)
                        }
                        .hidingSharedBackground()

                        ToolbarItem(placement: .primaryAction) {
                            if hostStore.appListStates[hostID] == .loading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button("刷新", systemImage: "arrow.clockwise") {
                                    Task { await hostStore.refreshApps(hostID: hostID) }
                                }
                                .disabled(!host.isPaired)
                            }
                        }
                    }
            } else {
                ContentUnavailableView("设备已删除", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task(id: hostID) {
            if hostStore.host(id: hostID)?.isPaired == true {
                await hostStore.refreshApps(hostID: hostID)
            }
        }
        .pairingSheet(hostID: hostID)
    }

    private func titleView(for host: StreamHost) -> some View {
        VStack(spacing: 1) {
            Text(host.name)
                .font(.headline)

            Text(host.displayAddress?.description ?? host.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(for host: StreamHost) -> some View {
        if host.pairState != .unpaired {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(host.apps) { app in
                        AppTile(
                            app: app,
                            hostID: host.id,
                            isConnected: host.isOnline && host.isPaired,
                            isRunning: host.currentGameID == app.id
                        )
                    }
                }
            }
            .contentMargins(20, for: .scrollContent)
            .overlay {
                if host.apps.isEmpty {
                    emptyAppsView(for: host)
                }
            }
        } else {
            pairPrompt(for: host)
        }
    }

    @ViewBuilder
    private func emptyAppsView(for host: StreamHost) -> some View {
        switch hostStore.appListStates[host.id] {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView(
                "无法获取应用列表",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case nil:
            ContentUnavailableView(
                "暂无应用",
                systemImage: "square.grid.2x2",
                description: Text("主机上还没有配置可串流的应用。")
            )
        }
    }

    /// Fallback for hosts that were unpaired on the server side after being opened.
    private func pairPrompt(for host: StreamHost) -> some View {
        ContentUnavailableView {
            Label("尚未配对", systemImage: "lock.fill")
        } description: {
            Text(host.isOnline
                 ? "配对后即可查看这台主机上的应用。"
                 : "主机当前离线，请确认主机已开机并与本设备处于同一网络。")
        } actions: {
            Button("开始配对") {
                hostStore.startPairing(hostID: host.id)
            }
            .prominentButtonStyle()
            .disabled(!host.isOnline)
        }
    }
}

private struct AppTile: View {
    let app: StreamApp
    let hostID: String
    let isConnected: Bool
    let isRunning: Bool

    @Environment(HostStore.self) private var hostStore
    @State private var artwork: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)

                if let artwork {
                    Image(decorative: artwork, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            // GameStream box art is 628×888
            .aspectRatio(628 / 888, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isRunning {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .padding(8)
                }
            }

            Text(app.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .task(id: isConnected ? app.id : nil) {
            // Box art is fetched again after every successful handshake
            artwork = isConnected ? await hostStore.artwork(for: app, hostID: hostID) : nil
        }
    }
}

private extension ToolbarContent {
    /// Keeps plain text toolbar items from getting a Liquid Glass background.
    @ToolbarContentBuilder
    func hidingSharedBackground() -> some ToolbarContent {
#if os(visionOS)
        self
#else
        sharedBackgroundVisibility(.hidden)
#endif
    }
}

#Preview {
    NavigationStack {
        DeviceDetailView(hostID: "preview")
    }
    .environment(HostStore())
}
