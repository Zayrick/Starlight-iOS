//
//  DevicesView.swift
//  Starlight
//
//  Created by Codex on 2026/7/24.
//

import SwiftUI

struct DevicesView: View {
    let searchText: String

    private let devices = Device.previewDevices
    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 20)
    ]

    private var filteredDevices: [Device] {
        guard !searchText.isEmpty else {
            return devices
        }

        return devices.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.detail.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        let visibleDevices = filteredDevices

        ScrollView {
            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(visibleDevices) { device in
                    DeviceCard(device: device)
                }
            }
        }
        .overlay {
            if visibleDevices.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .contentMargins(20, for: .scrollContent)
        .navigationTitle("设备")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加", systemImage: "plus") {}
            }
        }
        .toolbar(removing: .title)
    }
}

private struct DeviceCard: View {
    let device: Device
    @State private var isHovered = false
    @State private var isFavorite = false

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
            color: device.isOnline
                ? device.color.opacity(0.18)
                : Color.black.opacity(0.12),
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

            Button {} label: {
                Label("更多", systemImage: "ellipsis")
            }
        }
        .accessibilityIdentifier("device-card-\(device.id)")
    }

    private var cardContent: some View {
        ZStack {
            if device.isOnline {
                LinearGradient(
                    colors: [
                        device.color,
                        device.color.mix(with: .black, by: 0.36)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.78)

                PhotoWallBackground()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            } else {
                Color.gray.opacity(0.55)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            device.isOnline
                                ? Color.green
                                : Color.white.opacity(0.55)
                        )
                        .frame(width: 7, height: 7)

                    Text(device.isOnline ? "在线" : "离线")
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                Text(device.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(device.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.76))
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
        .foregroundStyle(.white)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
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
            .foregroundStyle(isFavorite ? .yellow : .white)
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

private struct PhotoWallBackground: View {
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
                            PhotoWallTile(row: row, column: column)
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

/// 照片墙中的单张 2:3 竖向卡片，目前为空，后续填充内容
private struct PhotoWallTile: View {
    let row: Int
    let column: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(0.12))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
            }
    }
}

private struct Device: Identifiable {
    let id: String
    let name: String
    let detail: String
    let color: Color
    let isOnline: Bool

    static let previewDevices = [
        Device(
            id: "studio",
            name: "工作室 Mac",
            detail: "Mac Studio · 工作室",
            color: .indigo,
            isOnline: true
        ),
        Device(
            id: "living-room",
            name: "客厅",
            detail: "Apple TV · 客厅",
            color: .blue,
            isOnline: true
        ),
        Device(
            id: "ipad",
            name: "iPad Pro",
            detail: "iPad · 随身设备",
            color: .teal,
            isOnline: false
        ),
        Device(
            id: "bedroom",
            name: "卧室 Mac mini",
            detail: "Mac mini · 卧室",
            color: .orange,
            isOnline: true
        )
    ]
}

#Preview {
    NavigationStack {
        DevicesView(searchText: "")
    }
    .frame(minWidth: 390, minHeight: 720)
}
