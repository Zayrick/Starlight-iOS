//
//  StreamSession.swift
//  Starlight
//
//  One streaming session: launches or resumes the app on the host, then runs
//  the moonlight-common-c connection and reports its progress.
//

import Foundation
import Observation

@Observable
final class StreamSession: Identifiable {
    enum Phase: Equatable {
        case starting(String)
        case streaming
        /// Ended normally by the host or the user.
        case ended
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .ended, .failed: true
            case .starting, .streaming: false
            }
        }
    }

    let id = UUID()
    let host: StreamHost
    let app: StreamApp
    let videoRenderer: VideoRenderer

    private(set) var phase: Phase = .starting("正在连接主机…")
    private(set) var isConnectionPoor = false

    /// Quit whatever else is running on the host before launching.
    @ObservationIgnored private let quitsRunningApp: Bool
    @ObservationIgnored private let audioRenderer = AudioRenderer()
    @ObservationIgnored private var client: MoonlightClient?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var isTornDown = false

    init(host: StreamHost, app: StreamApp, quitsRunningApp: Bool) {
        self.host = host
        self.app = app
        self.quitsRunningApp = quitsRunningApp
        videoRenderer = VideoRenderer()
    }

    // MARK: - Lifecycle

    func start() {
        guard launchTask == nil else { return }
        videoRenderer.onFirstFrame = { [weak self] in
            guard let self, !phase.isFinished else { return }
            phase = .streaming
        }
        launchTask = Task { await launch() }
    }

    /// Ends the stream, optionally quitting the app on the host too.
    func stop(quitApp: Bool = false) {
        if !phase.isFinished {
            phase = .ended
        }
        launchTask?.cancel()

        let stopping = teardown()
        guard quitApp, let address = host.activeAddress ?? host.displayAddress else { return }
        let gameStream = host.client(at: address)
        Task.detached {
            // The host only lets go of the app once our session is gone
            await stopping?.value
            try? await gameStream.quitApp()
        }
    }

    /// The last session's teardown. A new connection waits for it, otherwise
    /// the late SLStreamStop() would end the new connection instead.
    private static var pendingTeardown: Task<Void, Never>?

    /// Stops the connection off the main thread, since that blocks until
    /// moonlight-common-c's threads exit. Returns the task doing so, if any.
    @discardableResult
    private func teardown() -> Task<Void, Never>? {
        guard !isTornDown else { return nil }
        isTornDown = true
        guard let client else { return nil }
        let task = Task.detached(priority: .userInitiated) {
            client.stop()
        }
        Self.pendingTeardown = task
        return task
    }

    private func fail(_ message: String) {
        guard !phase.isFinished else { return }
        phase = .failed(message)
        teardown()
    }

    // MARK: - Launch

    private func launch() async {
        do {
            guard let address = host.activeAddress ?? host.displayAddress else {
                throw GameStreamError.unreachable("没有可用的主机地址")
            }
            let gameStream = host.client(at: address)

            let info = try await gameStream.serverInfo()
            guard info.uuid == host.id else {
                throw GameStreamError.unreachable("该地址上的主机已发生变化")
            }
            guard info.isPaired == true else {
                throw GameStreamError.notPaired
            }
            try Task.checkCancellation()

            let settings = ResolvedStreamSettings.load()
            var formats = settings.codec.videoFormats(hdr: settings.hdr && DisplayMetrics.supportsHDR)
            // Only ask for HDR when the host can encode 10-bit video
            let hostSupports10Bit = info.serverCodecModeSupport & (0x200 | 0x20000 | 0x100000 | 0x400000) != 0
            if !hostSupports10Bit {
                formats.subtract(.tenBitMask)
            }
            let hdr = !formats.isDisjoint(with: .tenBitMask)

            let resume: Bool
            if let runningID = info.currentGameID {
                if runningID == app.id {
                    resume = true
                } else if quitsRunningApp {
                    phase = .starting("正在退出正在运行的应用…")
                    try await gameStream.quitApp()
                    resume = false
                } else {
                    throw GameStreamError.server(code: 0, message: "主机上正在运行其他应用")
                }
            } else {
                resume = false
            }
            try Task.checkCancellation()

            var key = Data(count: 16)
            key.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 16) }
            let keyID = UInt32.random(in: 0...UInt32.max)

            phase = .starting(resume ? "正在恢复 \(app.name)…" : "正在启动 \(app.name)…")
            let sessionURL = try await gameStream.launch(
                LaunchRequest(
                    appID: app.id,
                    width: settings.size.width,
                    height: settings.size.height,
                    fps: settings.frameRate,
                    remoteInputKey: key,
                    remoteInputKeyID: keyID,
                    hdr: hdr,
                    surroundAudioInfo: MoonlightClient.surroundAudioInfo(channelCount: settings.audio.channelCount),
                    extraQuery: MoonlightClient.launchQueryParameters
                ),
                resume: resume,
                server: info
            )
            // Stopped while the host was launching the app
            guard !isTornDown else { return }

            phase = .starting("正在建立串流…")
            let configuration = MoonlightConfiguration(
                address: address.host,
                appVersion: info.appVersion ?? "7.1.431.-1",
                gfeVersion: info.gfeVersion,
                rtspSessionURL: sessionURL,
                serverCodecModeSupport: info.serverCodecModeSupport,
                width: settings.size.width,
                height: settings.size.height,
                fps: settings.frameRate,
                bitrateKbps: settings.bitrateKbps,
                audioChannelCount: settings.audio.channelCount,
                videoFormats: formats,
                fullColorRange: settings.colorRange == .full,
                remoteInputKey: key,
                remoteInputKeyID: keyID
            )
            await connect(configuration)
        } catch is CancellationError {
            // stop() already updated the phase
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func connect(_ configuration: MoonlightConfiguration) async {
        await Self.pendingTeardown?.value
        guard !isTornDown else { return }

        let client = MoonlightClient(videoRenderer: videoRenderer, audioRenderer: audioRenderer)
        self.client = client

        let events = client.events
        Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }

        let result = await Task.detached(priority: .userInitiated) {
            client.start(configuration)
        }.value

        if result != 0 {
            // A stage failure event usually arrives with a better message
            fail("无法建立串流连接（错误 \(result)）")
        }
    }

    // MARK: - Events

    private func handle(_ event: MoonlightClient.Event) {
        switch event {
        case .stageStarting(let stage):
            if case .starting = phase {
                phase = .starting("正在\(Self.localizedStage(stage))…")
            }

        case .stageFailed(let stage, let errorCode, let ports):
            // Interrupting a connection the user closed fails the current stage
            if phase == .ended { return }
            var message = "\(Self.localizedStage(stage))失败（错误 \(errorCode)）。"
            if let ports {
                message += "\n请确认防火墙没有阻止这些端口：\(ports)"
            }
            phase = .failed(message)
            teardown()

        case .connectionStarted:
            if case .starting = phase {
                phase = .starting("正在等待画面…")
            }

        case .connectionTerminated(let errorCode, let ports):
            guard !phase.isFinished else { return }
            if errorCode == 0 {
                phase = .ended
                teardown()
            } else {
                fail(Self.terminationMessage(errorCode: errorCode, ports: ports))
            }

        case .connectionStatusChanged(let isPoor):
            isConnectionPoor = isPoor
        }
    }

    private static func terminationMessage(errorCode: Int, ports: String?) -> String {
        var message = switch errorCode {
        case MoonlightClient.noVideoTrafficError:
            "没有收到主机的视频数据。"
        case MoonlightClient.noVideoFrameError:
            "网络状况不佳，无法接收完整的画面。"
        case MoonlightClient.protectedContentError:
            "主机上的内容受保护，无法串流。"
        default:
            "连接意外中断（错误 \(errorCode)）。"
        }
        if let ports {
            message += "\n请确认防火墙没有阻止这些端口：\(ports)"
        }
        return message
    }

    private static func localizedStage(_ stage: String) -> String {
        switch stage {
        case "platform initialization": "初始化"
        case "name resolution": "解析主机地址"
        case "audio stream initialization": "初始化音频流"
        case "RTSP handshake": "进行 RTSP 握手"
        case "control stream initialization": "初始化控制流"
        case "video stream initialization": "初始化视频流"
        case "input stream initialization": "初始化输入流"
        case "control stream establishment": "建立控制流"
        case "video stream establishment": "建立视频流"
        case "audio stream establishment": "建立音频流"
        case "input stream establishment": "建立输入流"
        default: stage
        }
    }
}
