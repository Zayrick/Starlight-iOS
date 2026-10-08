//
//  StreamSession.swift
//  Starlight
//
//  One streaming session: launches or resumes the app on the host, then runs
//  the moonlight-common-c connection and reports its progress.
//

import CoreGraphics
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
    @ObservationIgnored let input = StreamInput()

    private(set) var phase: Phase = .starting(String(localized: "Connecting to host…")) {
        didSet {
            // Also releases whatever is held down once the stream is over
            input.isEnabled = phase == .streaming
        }
    }
    private(set) var isConnectionPoor = false
    /// The latest measurements, nil until video arrives.
    private(set) var statistics: StreamStatistics?
    /// When the first frame showed up.
    private(set) var connectedAt: Date?

    /// Start out from the settings and can be changed while streaming.
    var touchEnabled: Bool
    var touchMode: TouchMode
    var mouseMode: MouseMode
    /// Remembered for later sessions.
    var showsStatistics: Bool {
        didSet {
            UserDefaults.standard.set(showsStatistics, forKey: StreamSettings.Key.showsStatistics)
        }
    }

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
        let inputSettings = InputSettings.load()
        touchEnabled = inputSettings.touchEnabled
        touchMode = inputSettings.touchMode
        mouseMode = inputSettings.mouseMode
        showsStatistics = UserDefaults.standard.bool(forKey: StreamSettings.Key.showsStatistics)
    }

    // MARK: - Lifecycle

    func start() {
        guard launchTask == nil else { return }
        videoRenderer.onFirstFrame = { [weak self] in
            guard let self, !phase.isFinished else { return }
            phase = .streaming
            connectedAt = .now
        }
        videoRenderer.onStatistics = { [weak self] statistics in
            guard let self, !phase.isFinished else { return }
            self.statistics = statistics
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
                throw GameStreamError.unreachable(String(localized: "No host address is available."))
            }
            let gameStream = host.client(at: address)

            let info = try await gameStream.serverInfo()
            guard info.uuid == host.id else {
                throw GameStreamError.unreachable(String(localized: "The host at this address has changed."))
            }
            guard info.isPaired == true else {
                throw GameStreamError.notPaired
            }
            try Task.checkCancellation()

            let settings = ResolvedStreamSettings.load()
            input.videoSize = CGSize(width: settings.size.width, height: settings.size.height)
            var formats = settings.codec.videoFormats(
                hdr: settings.hdr && DisplayMetrics.supportsHDR,
                yuv444: settings.yuv444
            )
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
                    phase = .starting(String(localized: "Quitting the running app…"))
                    try await gameStream.quitApp()
                    resume = false
                } else {
                    throw GameStreamError.server(code: 0, message: String(localized: "Another app is running on the host."))
                }
            } else {
                resume = false
            }
            try Task.checkCancellation()

            var key = Data(count: 16)
            key.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 16) }
            let keyID = UInt32.random(in: 0...UInt32.max)

            phase = .starting(resume
                ? String(localized: "Resuming \(app.name)…")
                : String(localized: "Opening \(app.name)…"))
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
                    optimizeGameSettings: settings.optimizeGameSettings,
                    playAudioOnHost: settings.playAudioOnHost,
                    extraQuery: MoonlightClient.launchQueryParameters
                ),
                resume: resume,
                server: info
            )
            // Stopped while the host was launching the app
            guard !isTornDown else { return }

            phase = .starting(String(localized: "Setting up the stream…"))
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
            fail(String(localized: "Couldn't set up the stream (error \(result))."))
        }
    }

    // MARK: - Events

    private func handle(_ event: MoonlightClient.Event) {
        switch event {
        case .stageStarting(let stage):
            if case .starting = phase {
                phase = .starting(String(localized: "\(Self.localizedStage(stage))…", comment: "Progress while connecting; the argument is a connection stage"))
            }

        case .stageFailed(let stage, let errorCode, let ports):
            // Interrupting a connection the user closed fails the current stage
            if phase == .ended { return }
            var message = String(localized: "\(Self.localizedStage(stage)) failed (error \(errorCode)).", comment: "The argument is a connection stage")
            if let ports {
                message += "\n" + Self.firewallHint(ports: ports)
            }
            phase = .failed(message)
            teardown()

        case .connectionStarted:
            if case .starting = phase {
                phase = .starting(String(localized: "Waiting for video…"))
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

        case .gamepadFeedback(let gamepad, let feedback):
            input.gamepads.apply(feedback, to: gamepad)
        }
    }

    private static func terminationMessage(errorCode: Int, ports: String?) -> String {
        var message = switch errorCode {
        case MoonlightClient.noVideoTrafficError:
            String(localized: "No video was received from the host.")
        case MoonlightClient.noVideoFrameError:
            String(localized: "The network connection is too poor to receive complete frames.")
        case MoonlightClient.protectedContentError:
            String(localized: "The content on the host is protected and can't be streamed.")
        default:
            String(localized: "The connection was interrupted (error \(errorCode)).")
        }
        if let ports {
            message += "\n" + firewallHint(ports: ports)
        }
        return message
    }

    private static func firewallHint(ports: String) -> String {
        String(localized: "Make sure your firewall isn't blocking these ports: \(ports)")
    }

    private static func localizedStage(_ stage: String) -> String {
        switch stage {
        case "platform initialization": String(localized: "Initialization")
        case "name resolution": String(localized: "Host address lookup")
        case "audio stream initialization": String(localized: "Audio stream setup")
        case "RTSP handshake": String(localized: "RTSP handshake")
        case "control stream initialization": String(localized: "Control stream setup")
        case "video stream initialization": String(localized: "Video stream setup")
        case "input stream initialization": String(localized: "Input stream setup")
        case "control stream establishment": String(localized: "Control stream connection")
        case "video stream establishment": String(localized: "Video stream connection")
        case "audio stream establishment": String(localized: "Audio stream connection")
        case "input stream establishment": String(localized: "Input stream connection")
        default: stage
        }
    }
}
