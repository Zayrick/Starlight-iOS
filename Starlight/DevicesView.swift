//
//  DevicesView.swift
//  Starlight
//
//  Created by Codex on 2026/7/24.
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

struct DevicesView: View {
    @Binding var searchText: String

    private let devices = Device.previewDevices
    private let cardSpacing: CGFloat = 20

    private var filteredDevices: [Device] {
        guard !searchText.isEmpty else {
            return devices
        }

        return devices.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.detail.localizedStandardContains(searchText)
        }
    }

    private var columns: [GridItem] {
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return [GridItem(.flexible())]
        }
#endif

        return [
            GridItem(
                .adaptive(minimum: 280, maximum: 440),
                spacing: cardSpacing
            )
        ]
    }

    var body: some View {
        ScrollView {
            if filteredDevices.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical)
            } else {
                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: cardSpacing
                ) {
                    ForEach(filteredDevices) { device in
                        DeviceCard(device: device)
                    }
                }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .contentMargins(.vertical, 20, for: .scrollContent)
        .navigationTitle("设备")
        .toolbar {
#if os(visionOS)
            ToolbarItem(placement: .primaryAction) {
                Button("添加", systemImage: "plus") {}
            }
#else
            ToolbarSpacer(.flexible)

            ToolbarItem {
                Button("添加", systemImage: "plus") {}
            }
#endif
        }
        .toolbar(removing: .title)
    }
}

private struct DeviceCard: View {
    let device: Device
    @State private var isHovered = false
    @State private var isFavorite = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    device.color,
                    device.color.mix(with: .black, by: 0.36)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .saturation(device.isOnline ? 1 : 0)

            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 190, height: 190)
                .scaleEffect(isHovered ? 1.12 : 1)
                .offset(x: 115, y: 90)
                .blur(radius: 2)

            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 110, height: 110)
                .scaleEffect(isHovered ? 1.16 : 1)
                .offset(x: -145, y: -95)

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

            if isHovered {
                Group {
#if os(visionOS)
                    cardActionButtons
#else
                    GlassEffectContainer(spacing: 4) {
                        cardActionButtons
                    }
#endif
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .padding(10)
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(
            color: device.isOnline
                ? device.color.opacity(0.18)
                : Color.black.opacity(0.12),
            radius: 16,
            y: 8
        )
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.smooth(duration: 0.8), value: isHovered)
        .accessibilityIdentifier("device-card-\(device.id)")
    }

    private var cardActionButtons: some View {
        HStack(spacing: 8) {
            CardActionButton(
                title: isFavorite ? "取消收藏" : "收藏",
                systemImage: isFavorite ? "star.fill" : "star",
                foregroundStyle: isFavorite ? .yellow : .white
            ) {
                isFavorite.toggle()
            }

            CardActionButton(
                title: "更多",
                systemImage: "ellipsis",
                foregroundStyle: .white
            ) {}
        }
    }
}

private struct CardActionButton: View {
    let title: String
    let systemImage: String
    let foregroundStyle: Color
    let action: () -> Void

    var body: some View {
        styledButton
            .accessibilityLabel(title)
            .help(title)
    }

    @ViewBuilder
    private var styledButton: some View {
#if os(visionOS)
        button
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
#else
        button
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
#endif
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
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
        DevicesView(searchText: .constant(""))
    }
    .frame(minWidth: 390, minHeight: 720)
}
