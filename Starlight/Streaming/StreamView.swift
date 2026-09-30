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

#if os(iOS)
            if !session.phase.isFinished {
                // Kept just clear of the screen's edge
                StreamEdgeHandle(menu: controlsMenu)
                    .padding(2)
            }
#endif
        }
        .ignoresSafeArea()
#if !os(iOS)
        .overlay(alignment: .topTrailing) {
            if !session.phase.isFinished {
                controlsMenu
                    .padding(16)
            }
        }
#endif
        .overlay(alignment: .topLeading) {
            statisticsList
#if os(iOS)
                // Right against the safe area, the edge handle is outside of it
                .padding(.leading, 4)
#else
                .padding(8)
#endif
        }
        // Clear of the edge handle and the menu button
        .overlay(alignment: .top) {
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
        .animation(.smooth, value: session.showsStatistics)
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
    private var statisticsList: some View {
        if session.phase == .streaming, session.showsStatistics,
           let statistics = session.statistics, let connectedAt = session.connectedAt {
            VStack(alignment: .leading, spacing: 2) {
                // Ticks on its own, statistics only arrive with video
                TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(connectedAt))
                        .formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2))))
                }
                ForEach(Array(statistics.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            // 70% of the caption2 size
#if os(macOS)
            .font(.system(size: 7, weight: .semibold).monospacedDigit())
#else
            .font(.system(size: 8, weight: .semibold).monospacedDigit())
#endif
            // 30% transparent
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            // Readable over bright pictures too
            .shadow(color: .black.opacity(0.8), radius: 2)
                // Touches and clicks go through to the stream
                .allowsHitTesting(false)
                .transition(.opacity)
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

#if os(iOS)
    /// Built when it opens, so it shows the current settings.
    private var controlsMenu: UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [session, streamController] completion in
                let touch = UIAction(
                    title: "触控", image: UIImage(systemName: "hand.point.up.left"),
                    state: session.touchEnabled ? .on : .off
                ) { _ in
                    session.touchEnabled.toggle()
                }

                let mouseModes = MouseMode.allCases.map { mode in
                    UIAction(title: mode.title, state: session.mouseMode == mode ? .on : .off) { _ in
                        session.mouseMode = mode
                    }
                }
                let mouseMode = UIMenu(
                    title: "鼠标模式", subtitle: session.mouseMode.title,
                    image: UIImage(systemName: "cursorarrow"), options: .singleSelection,
                    children: mouseModes
                )

                let statistics = UIAction(
                    title: "串流信息", image: UIImage(systemName: "chart.bar.xaxis"),
                    state: session.showsStatistics ? .on : .off
                ) { _ in
                    session.showsStatistics.toggle()
                }

                completion([
                    UIMenu(options: .displayInline, children: [statistics]),
                    UIMenu(options: .displayInline, children: [touch, mouseMode]),
                    UIAction(title: "断开连接", image: UIImage(systemName: "xmark")) { _ in
                        streamController.close()
                    },
                    UIAction(title: "退出应用", image: UIImage(systemName: "power"), attributes: .destructive) { _ in
                        streamController.close(quitApp: true)
                    },
                ])
            },
        ])
    }
#else
    private var controlsMenu: some View {
        Menu {
            Section {
                Toggle("串流信息", systemImage: "chart.bar.xaxis", isOn: $session.showsStatistics)
            }

#if os(macOS)
            Section {
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
#endif
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
