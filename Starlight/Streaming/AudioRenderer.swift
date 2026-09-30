//
//  AudioRenderer.swift
//  Starlight
//
//  Plays the decoded audio stream, pulling samples from the bridge on the
//  real-time audio thread.
//

import AVFoundation
import os

nonisolated final class AudioRenderer: MoonlightAudioRenderer, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?

    private static let logger = Logger(subsystem: "Starlight", category: "AudioRenderer")

    func start(channelCount: Int, sampleRate: Int) -> Bool {
        // Host channel order is FL FR FC LFE BL BR SL SR, which is the WAVE order
        let layoutTag: AudioChannelLayoutTag = switch channelCount {
        case 8: kAudioChannelLayoutTag_WAVE_7_1
        case 6: kAudioChannelLayoutTag_WAVE_5_1_A
        default: kAudioChannelLayoutTag_Stereo
        }
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag),
              layout.channelCount == channelCount else {
            Self.logger.error("Unsupported channel count \(channelCount)")
            return false
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channelLayout: layout)

#if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            // Keep the hardware buffer short, the stream is latency sensitive
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            Self.logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
#endif

        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            MoonlightClient.renderAudio(UnsafeMutableAudioBufferListPointer(audioBufferList), frameCount: Int(frameCount))
            return noErr
        }
        self.sourceNode = sourceNode
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        // The engine stops when the output device changes, e.g. headphones are plugged in
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.restart()
        }

        do {
            try engine.start()
            return true
        } catch {
            Self.logger.error("Failed to start audio engine: \(error.localizedDescription)")
            stop()
            return false
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        // Synchronous, so the render block is done with the bridge afterwards
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
#if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    private func restart() {
        guard sourceNode != nil, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            Self.logger.error("Failed to restart audio engine: \(error.localizedDescription)")
        }
    }
}
