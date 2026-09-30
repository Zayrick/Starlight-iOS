//
//  StreamView.swift
//  Starlight
//

import AVFoundation
import SwiftUI

struct StreamView: View {
    @Bindable var session: StreamSession

    @Environment(StreamController.self) private var streamController

    var body: some View {
        ZStack {
            Color.black

            StreamSurface(
                layer: session.videoRenderer.displayLayer,
                input: session.input,
                isActive: session.phase == .streaming,
                touchEnabled: session.touchEnabled,
                mouseMode: session.mouseMode
            )
            .opacity(session.phase == .streaming ? 1 : 0)

            statusOverlay
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if !session.phase.isFinished {
                controlsMenu
                    .padding(16)
            }
        }
        .overlay(alignment: .topLeading) {
            if session.phase == .streaming, session.isConnectionPoor {
                Label("网络状况不佳", systemImage: "wifi.exclamationmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: session.phase)
        .animation(.smooth, value: session.isConnectionPoor)
        .environment(\.colorScheme, .dark)
#if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Touches near the edges belong to the host first
        .defersSystemGestures(on: .all)
#endif
        .keepsDisplayAwake()
        .onChange(of: session.phase) { _, phase in
            // Only failures stay on screen to explain what went wrong
            if phase == .ended {
                streamController.close()
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.phase {
        case .starting(let status):
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                VStack(spacing: 4) {
                    Text(session.app.name)
                        .font(.title2.weight(.semibold))

                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            .multilineTextAlignment(.center)
            .padding()

        case .streaming, .ended:
            EmptyView()

        case .failed(let message):
            ContentUnavailableView {
                Label("串流失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("关闭") {
                    streamController.close()
                }
                .prominentButtonStyle()
            }
        }
    }

    private var controlsMenu: some View {
        Menu {
#if !os(visionOS)
            Section {
#if os(iOS)
                Toggle("触控", systemImage: "hand.point.up.left", isOn: $session.touchEnabled)
#endif

                Picker("鼠标模式", systemImage: "cursorarrow", selection: $session.mouseMode) {
                    ForEach(MouseMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }
#endif

            Button("断开连接", systemImage: "xmark") {
                streamController.close()
            }

            Button("退出应用", systemImage: "power", role: .destructive) {
                streamController.close(quitApp: true)
            }
        } label: {
            Label("串流选项", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .streamControlBackground()
        // Stay out of the way of the picture
        .opacity(session.phase == .streaming ? 0.6 : 1)
    }
}

private extension View {
    @ViewBuilder
    func streamControlBackground() -> some View {
#if os(visionOS)
        glassBackgroundEffect(in: .circle)
#else
        glassEffect(.regular.interactive(), in: .circle)
#endif
    }

    /// Prevents the display from dimming or sleeping while visible.
    func keepsDisplayAwake() -> some View {
        modifier(KeepsDisplayAwake())
    }
}

private struct KeepsDisplayAwake: ViewModifier {
#if os(macOS)
    @State private var activity: NSObjectProtocol?
#endif

    func body(content: Content) -> some View {
        content
            .onAppear {
#if os(macOS)
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
                    reason: "Streaming"
                )
#else
                UIApplication.shared.isIdleTimerDisabled = true
#endif
            }
            .onDisappear {
#if os(macOS)
                if let activity {
                    ProcessInfo.processInfo.endActivity(activity)
                }
                activity = nil
#else
                UIApplication.shared.isIdleTimerDisabled = false
#endif
            }
    }
}
