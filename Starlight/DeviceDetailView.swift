//
//  DeviceDetailView.swift
//  Starlight
//

import SwiftUI

struct DeviceDetailView: View {
    let hostID: String

    @Environment(HostStore.self) private var hostStore
    @Environment(StreamController.self) private var streamController
    /// App waiting for confirmation to replace the one running on the host.
    @State private var pendingLaunch: StreamApp?
    @State private var quitErrorMessage: String?
    @State private var isConfirmingQuit = false
    @State private var isQuitting = false

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
            let runningApp = runningApp(for: host)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let runningApp {
                        runningAppCard(runningApp, on: host)
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(host.apps.filter { $0.id != host.currentGameID }) { app in
                            appButton(app, on: host)
                        }
                    }
                }
                .animation(.default, value: host.currentGameID)
            }
            .contentMargins(20, for: .scrollContent)
            .overlay {
                if host.apps.isEmpty && runningApp == nil {
                    emptyAppsView(for: host)
                }
            }
            .confirmationDialog(
                runningAppTitle(for: host),
                isPresented: Binding {
                    pendingLaunch != nil
                } set: { isPresented in
                    if !isPresented {
                        pendingLaunch = nil
                    }
                },
                titleVisibility: .visible,
                presenting: pendingLaunch
            ) { app in
                Button("退出并启动 \(app.name)", role: .destructive) {
                    streamController.start(host: host, app: app, quitsRunningApp: true)
                }
            } message: { _ in
                Text("主机同一时间只能运行一个应用，未保存的进度将会丢失。")
            }
            .alert(
                "无法退出应用",
                isPresented: Binding {
                    quitErrorMessage != nil
                } set: { isPresented in
                    if !isPresented {
                        quitErrorMessage = nil
                    }
                }
            ) {
                Button("好") {}
            } message: {
                Text(quitErrorMessage ?? "")
            }
            .alert(
                "退出“\(runningApp?.name ?? "应用")”？",
                isPresented: $isConfirmingQuit
            ) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    quitRunningApp(on: host)
                }
            } message: {
                Text("未保存的进度将会丢失。")
            }
        } else {
            pairPrompt(for: host)
        }
    }

    private func appButton(_ app: StreamApp, on host: StreamHost) -> some View {
        let isConnected = host.isOnline && host.isPaired

        return Button {
            if host.currentGameID != nil {
                pendingLaunch = app
            } else {
                streamController.start(host: host, app: app)
            }
        } label: {
            AppTile(app: app, hostID: host.id, isConnected: isConnected)
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
    }

    private func runningAppCard(_ app: StreamApp, on host: StreamHost) -> some View {
        RunningAppCard(
            app: app,
            hostID: host.id,
            isConnected: host.isOnline && host.isPaired,
            isQuitting: isQuitting,
            resume: { streamController.start(host: host, app: app) },
            quit: { isConfirmingQuit = true }
        )
    }

    /// The app running on the host, even if it's missing from the app list.
    private func runningApp(for host: StreamHost) -> StreamApp? {
        guard let runningID = host.currentGameID else { return nil }
        return host.apps.first { $0.id == runningID }
            ?? StreamApp(id: runningID, name: "未知应用", isHDRSupported: false)
    }

    private func runningAppTitle(for host: StreamHost) -> String {
        let name = host.apps.first { $0.id == host.currentGameID }?.name ?? "其他应用"
        return "“\(name)”正在运行"
    }

    private func quitRunningApp(on host: StreamHost) {
        guard !isQuitting else { return }
        isQuitting = true
        Task {
            defer { isQuitting = false }
            do {
                try await hostStore.quitApp(hostID: host.id)
            } catch {
                quitErrorMessage = error.localizedDescription
            }
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

    @Environment(HostStore.self) private var hostStore
    @State private var artwork: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BoxArt(artwork: artwork, cornerRadius: 14)

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

/// Shows the app running on the host with shortcuts to resume or quit it.
private struct RunningAppCard: View {
    let app: StreamApp
    let hostID: String
    let isConnected: Bool
    let isQuitting: Bool
    let resume: () -> Void
    let quit: () -> Void

    @Environment(HostStore.self) private var hostStore
    @State private var artwork: CGImage?

    var body: some View {
        HStack(spacing: 14) {
            BoxArt(artwork: artwork, cornerRadius: 8)
                .frame(width: 48)

            Text(app.name)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("继续", systemImage: "play.fill", action: resume)
                .prominentButtonStyle()

            Button(role: .destructive, action: quit) {
                if isQuitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("退出", systemImage: "power")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(isQuitting)
        }
        .disabled(!isConnected)
        .task(id: isConnected ? app.id : nil) {
            artwork = isConnected ? await hostStore.artwork(for: app, hostID: hostID) : nil
        }
    }
}

/// App box art, or a placeholder while it's unavailable.
private struct BoxArt: View {
    let artwork: CGImage?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
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
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
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
    .environment(StreamController())
}
