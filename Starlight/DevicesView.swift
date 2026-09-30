//
//  DevicesView.swift
//  Starlight
//
//  Created by Codex on 2026/7/24.
//

import SwiftUI

struct DevicesView: View {
    let searchText: String

    @Environment(HostStore.self) private var hostStore
    @State private var isAddingDevice = false
    @State private var selectedHostID: String?
    /// Host whose pairing was started by tapping its card.
    @State private var pairingHostID: String?
    @State private var unavailableHost: UnavailableHost?

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 20)
    ]

    private var filteredHosts: [StreamHost] {
        guard !searchText.isEmpty else {
            return hostStore.hosts
        }

        return hostStore.hosts.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.detailText.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        let visibleHosts = filteredHosts

        ScrollView {
            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(visibleHosts) { host in
                    Button {
                        open(host)
                    } label: {
                        DeviceCard(host: host)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if visibleHosts.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView {
                        Label("正在搜索设备", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("正在局域网中查找运行 Sunshine 的主机，也可以手动添加主机地址。")
                    } actions: {
                        Button("添加设备") {
                            isAddingDevice = true
                        }
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .contentMargins(20, for: .scrollContent)
        .navigationTitle("设备")
        .navigationDestination(item: $selectedHostID) { hostID in
            DeviceDetailView(hostID: hostID)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加", systemImage: "plus") {
                    isAddingDevice = true
                }
            }
        }
        .toolbar(removing: .title)
        .sheet(isPresented: $isAddingDevice) {
            AddDeviceView()
        }
        .pairingSheet(hostID: pairingHostID)
        .onChange(of: hostStore.pairing) { _, pairing in
            guard pairing == nil, let hostID = pairingHostID else { return }
            pairingHostID = nil
            // Pairing finished; open the device only if it actually succeeded
            if hostStore.host(id: hostID)?.isPaired == true {
                selectedHostID = hostID
            }
        }
        .alert(
            unavailableHost?.title ?? "",
            isPresented: Binding(
                get: { unavailableHost != nil },
                set: { if !$0 { unavailableHost = nil } }
            ),
            presenting: unavailableHost
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { host in
            Text(host.message)
        }
    }

    /// Offline hosts can't be opened; paired hosts open directly and
    /// unpaired hosts go through pairing first.
    private func open(_ host: StreamHost) {
        if !host.isConnected {
            unavailableHost = UnavailableHost(name: host.name, isOffline: host.status == .offline)
        } else if host.isPaired {
            selectedHostID = host.id
        } else {
            pairingHostID = host.id
            hostStore.startPairing(hostID: host.id)
        }
    }
}

private struct UnavailableHost {
    let name: String
    let isOffline: Bool

    var title: String {
        isOffline ? "设备离线" : "正在连接"
    }

    var message: String {
        isOffline
            ? "无法连接到“\(name)”，请确认主机已开机并与本设备处于同一网络。"
            : "正在与“\(name)”建立连接，请稍候再试。"
    }
}

private struct DeviceCard: View {
    let host: StreamHost

    @Environment(HostStore.self) private var hostStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isFavorite = false

    /// 与当前主题一致的遮罩色，用于压暗/提亮封面墙以突出文字
    private var scrimColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        Group {
#if os(visionOS)
            cardContent
                .glassBackgroundEffect(
                    in: .rect(cornerRadius: 22, style: .continuous)
                )
#else
            cardContent
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 22, style: .continuous)
                )
#endif
        }
        .shadow(
            color: .black.opacity(host.isConnected ? 0.16 : 0.1),
            radius: 16,
            y: 8
        )
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
#if os(iOS)
        .contentShape(
            .contextMenuPreview,
            .rect(cornerRadius: 22, style: .continuous)
        )
#endif
        .onHover { isHovered = $0 }
        .animation(.smooth(duration: 0.8), value: isHovered)
        .contextMenu {
            Toggle(isOn: $isFavorite) {
                Label("收藏", systemImage: "star")
            }

            Divider()

            Button(role: .destructive) {
                hostStore.removeHost(id: host.id)
            } label: {
                Label("删除设备", systemImage: "trash")
            }
        }
        .task(id: host.isOnline && host.isPaired) {
            // Fetch the app list once so the background can show box art
            if host.isOnline, host.isPaired, host.apps.isEmpty,
               hostStore.appListStates[host.id] == nil {
                await hostStore.refreshApps(hostID: host.id)
            }
        }
    }

    private var wallContent: PhotoWallContent {
        if host.status == .offline {
            return .symbol("personalhotspot.slash")
        }
        switch host.pairState {
        case .paired: return .artwork(hostID: host.id, apps: host.apps)
        case .unpaired: return .symbol("lock.fill")
        case .unknown: return .blank
        }
    }

    private var cardContent: some View {
        ZStack {
            PhotoWallBackground(content: wallContent)

            vignette

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            host.isConnected
                                ? Color.green
                                : Color.secondary
                        )
                        .frame(width: 7, height: 7)

                    Text(host.statusLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(host.isConnected ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                Text(host.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(host.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            .padding(14)
            .accessibilityElement(children: .combine)

#if os(macOS)
            if isHovered {
                GlassEffectContainer(spacing: 4) {
                    cardActionButtons
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .padding(10)
                .transition(.opacity)
            }
#endif
        }
        .foregroundStyle(.primary)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    /// 四周晕影 + 上下渐变遮罩，让文字区域落在干净的底色上
    private var vignette: some View {
        ZStack {
            EllipticalGradient(
                colors: [scrimColor.opacity(0.15), scrimColor.opacity(0.7)],
                center: .center,
                startRadiusFraction: 0.1,
                endRadiusFraction: 0.75
            )

            // 顶部状态行
            LinearGradient(
                stops: [
                    .init(color: scrimColor.opacity(0.75), location: 0),
                    .init(color: scrimColor.opacity(0), location: 0.35)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 底部名称与地址
            LinearGradient(
                stops: [
                    .init(color: scrimColor.opacity(0), location: 0.3),
                    .init(color: scrimColor.opacity(0.85), location: 0.75),
                    .init(color: scrimColor.opacity(0.95), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

#if os(macOS)
    private var cardActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                isFavorite.toggle()
            } label: {
                Label(
                    isFavorite ? "取消收藏" : "收藏",
                    systemImage: isFavorite ? "star.fill" : "star"
                )
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .foregroundStyle(isFavorite ? .yellow : .primary)
            .help(isFavorite ? "取消收藏" : "收藏")

            Button {} label: {
                Label("更多", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("更多")
        }
    }
#endif
}

private enum PhotoWallContent: Equatable {
    case blank
    /// Each tile shows the same SF Symbol, e.g. a lock when unpaired.
    case symbol(String)
    /// Box art of the host's apps, repeated to fill every tile.
    case artwork(hostID: String, apps: [StreamApp])
}

private struct PhotoWallBackground: View {
    var content: PhotoWallContent = .blank
    var tileWidth: CGFloat = 56
    var spacing: CGFloat = 10
    var angle: Angle = .degrees(-16)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let tileHeight = tileWidth * 3 / 2
            let stepX = tileWidth + spacing
            let stepY = tileHeight + spacing
            // 旋转后仍需铺满卡片，按对角线长度计算网格尺寸
            let diagonal = (size.width * size.width + size.height * size.height)
                .squareRoot()
            let columnCount = Int((diagonal / stepX).rounded(.up)) + 2
            let rowCount = Int((diagonal / stepY).rounded(.up)) + 1

            VStack(spacing: spacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            PhotoWallTile(
                                content: content,
                                index: row * columnCount + column
                            )
                            .frame(width: tileWidth, height: tileHeight)
                        }
                    }
                    // 相邻行错开半格
                    .offset(x: row.isMultiple(of: 2) ? 0 : stepX / 2)
                }
            }
            .frame(width: diagonal, height: diagonal)
            .rotationEffect(angle)
            .frame(width: size.width, height: size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 照片墙中的单张 2:3 竖向卡片，按内容显示空白、锁或应用封面
private struct PhotoWallTile: View {
    let content: PhotoWallContent
    let index: Int

    @Environment(HostStore.self) private var hostStore
    @State private var artwork: CGImage?

    private var app: (hostID: String, app: StreamApp)? {
        guard case .artwork(let hostID, let apps) = content, !apps.isEmpty else {
            return nil
        }
        // 按顺序铺封面，起始位置随机；以主机 ID 为种子，重绘时保持不变
        let seed = hostID.unicodeScalars.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1.value) }
        let start = Int(Self.mix(seed) % UInt64(apps.count))
        return (hostID, apps[(start + index) % apps.count])
    }

    /// SplitMix64 混淆，把相邻的种子打散成均匀分布
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.primary.opacity(0.08))
            .overlay {
                if let artwork, app != nil {
                    Image(decorative: artwork, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if case .symbol(let name) = content {
                    Image(systemName: name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.primary.opacity(0.1), lineWidth: 0.5)
            }
            .task(id: app?.app.id) {
                guard let app else {
                    artwork = nil
                    return
                }
                artwork = await hostStore.artwork(for: app.app, hostID: app.hostID)
            }
    }
}

extension StreamHost {
    var statusText: String {
        switch status {
        case .unknown: "正在连接"
        case .online where pairState == .unknown: "正在连接"
        case .online: currentGameID == nil ? "在线" : "串流中"
        case .offline: "离线"
        }
    }

    var pairText: String? {
        switch pairState {
        case .paired: "已配对"
        case .unpaired: "未配对"
        case .unknown: nil
        }
    }

    /// Connection status followed by pair status, e.g. "在线 · 已配对".
    var statusLine: String {
        guard let pairText else { return statusText }
        return "\(statusText) · \(pairText)"
    }

    var detailText: String {
        displayAddress?.description ?? "暂无地址"
    }
}

#Preview {
    NavigationStack {
        DevicesView(searchText: "")
    }
    .environment(HostStore())
    .frame(minWidth: 390, minHeight: 720)
}
