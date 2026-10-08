//
//  StreamDrawer.swift
//  Starlight
//
//  The panel the edge handle pulls out from the left, with the stream's
//  controls. It only covers a strip of the picture, so changes show right
//  away next to it.
//

#if os(iOS)
import SwiftUI

struct StreamDrawer: View {
    static let width: CGFloat = 300

    @Bindable var session: StreamSession

    @Environment(StreamController.self) private var streamController

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    HStack(spacing: 10) {
                        Toggle("Stream Stats", systemImage: "chart.bar.xaxis", isOn: $session.showsStatistics)
                        Toggle("Touch", systemImage: "hand.point.up.left", isOn: $session.touchEnabled)
                    }
                    .toggleStyle(TileToggleStyle())

                    section("Touch Mode") {
                        Picker("Touch Mode", selection: $session.touchMode) {
                            ForEach(TouchMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(!session.touchEnabled)
                    }

                    section("Mouse Mode") {
                        Picker("Mouse Mode", selection: $session.mouseMode) {
                            ForEach(MouseMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    section("Shortcuts") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(Shortcut.all) { shortcut in
                                Button {
                                    session.input.typeShortcut(shortcut.keys)
                                } label: {
                                    Text(shortcut.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.roundedRectangle(radius: 10))
                                .tint(.white)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Keeps the scroll bar clear of the rounded top corners
            .contentMargins(.top, 20, for: .scrollIndicators)

            HStack(spacing: 10) {
                Button {
                    streamController.close()
                } label: {
                    Label("Disconnect", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.white)

                Button(role: .destructive) {
                    streamController.close(quitApp: true)
                } label: {
                    Label("Quit App", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
            .padding(16)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // The glass only draws behind; scrolled content needs clipping too
        .clipShape(Self.shape)
        .glassEffect(.regular, in: Self.shape)
    }

    private static let shape = ConcentricRectangle(corners: .concentric(minimum: 24), isUniform: true)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.app.name)
                .font(.headline)
            Text(session.host.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let statistics = session.statistics {
                Text(statistics.summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .lineLimit(1)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// A key combination sent to the host with one tap, for keys a touch
/// screen doesn't have.
private struct Shortcut: Identifiable {
    let title: String
    let keys: [VirtualKey]

    var id: String { title }

    private static let escape = VirtualKey(code: 0x1B)
    private static let tab = VirtualKey(code: 0x09)
    private static let enter = VirtualKey(code: 0x0D)
    private static let d = VirtualKey(code: 0x44)

    static let all = [
        Shortcut(title: "Esc", keys: [escape]),
        Shortcut(title: "Win", keys: [.leftMeta]),
        Shortcut(title: "Alt+Tab", keys: [.leftAlt, tab]),
        Shortcut(title: String(localized: "Show Desktop"), keys: [.leftMeta, d]),
        Shortcut(title: String(localized: "Toggle Full Screen"), keys: [.leftAlt, enter]),
        Shortcut(title: String(localized: "Task Manager"), keys: [.leftControl, .leftShift, escape]),
    ]
}

/// A tile that lights up while on, like the ones in Control Center.
private struct TileToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.title3)
                configuration.label
                    .labelStyle(.titleOnly)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .foregroundStyle(configuration.isOn ? .black : .white)
            .background(
                configuration.isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.fill.tertiary),
                in: .rect(cornerRadius: 16)
            )
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .animation(.smooth(duration: 0.2), value: configuration.isOn)
    }
}

private extension StreamStatistics {
    /// One line for the drawer's header.
    var summary: String {
        var parts = [
            "\(width)×\(height)",
            "\(frameRate.formatted(.number.precision(.fractionLength(0)))) FPS",
            "\((bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps",
        ]
        if let roundTripTimeMs {
            parts.append("\(roundTripTimeMs) ms")
        }
        return parts.joined(separator: " · ")
    }
}
#endif
