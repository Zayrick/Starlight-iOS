//
//  SettingsView.swift
//  Starlight
//
//  Created by Codex on 2026/7/24.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(StreamSettings.Key.resolution) private var resolution = StreamSettings.defaultResolution
    @AppStorage(StreamSettings.Key.frameRate) private var frameRate = StreamSettings.defaultFrameRate
    @AppStorage(StreamSettings.Key.bitrateKbps) private var bitrateKbps = StreamSettings.defaultBitrateKbps
    @AppStorage(StreamSettings.Key.codec) private var codec = VideoCodecPreference.auto
    @AppStorage(StreamSettings.Key.hdr) private var hdrEnabled = false
    @AppStorage(StreamSettings.Key.yuv444) private var yuv444Enabled = false
    @AppStorage(StreamSettings.Key.colorRange) private var colorRange = StreamColorRange.limited
    @AppStorage(StreamSettings.Key.audio) private var audio = StreamAudioConfiguration.stereo
    @AppStorage(StreamSettings.Key.optimizeGameSettings) private var optimizeGameSettings = StreamSettings.defaultOptimizeGameSettings
    @AppStorage(StreamSettings.Key.playAudioOnHost) private var playAudioOnHost = StreamSettings.defaultPlayAudioOnHost
    @AppStorage(StreamSettings.Key.touchInput) private var touchEnabled = InputSettings.defaultTouchEnabled
    @AppStorage(StreamSettings.Key.touchMode) private var touchMode = InputSettings.defaultTouchMode
    @AppStorage(StreamSettings.Key.mouseMode) private var mouseMode = InputSettings.defaultMouseMode
    @AppStorage(StreamSettings.Key.gamepadEmulation) private var gamepadEmulation = GamepadSettings.defaultEmulation
    @AppStorage(StreamSettings.Key.gamepadSwapsButtons) private var gamepadSwapsButtons = GamepadSettings.defaultSwapsButtons
    @AppStorage(StreamSettings.Key.gamepadFeedback) private var gamepadFeedback = GamepadSettings.defaultFeedback
    @AppStorage(StreamSettings.Key.gamepadUsesDevice) private var gamepadUsesDevice = GamepadSettings.defaultUsesDevice

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $resolution) {
                    ForEach(StreamResolution.availableCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }

                Picker("Frame Rate", selection: $frameRate) {
                    ForEach(StreamSettings.frameRates, id: \.self) { fps in
                        Text("\(fps) FPS").tag(fps)
                    }
                }

                VStack(alignment: .leading) {
                    LabeledContent("Bitrate", value: Self.formatMbps(bitrateKbps))
                    Slider(value: bitrateMbps, in: bitrateMbpsRange, step: 0.5)
                }

                Toggle("Optimize Game Settings", isOn: $optimizeGameSettings)
            } header: {
                Text("Video")
            } footer: {
                Text("Recommended bitrate: \(Self.formatMbps(recommendedBitrateKbps)). It resets when you change the resolution or frame rate.\nOptimize Game Settings lets the host adjust the game's graphics settings to match the stream.")
            }

            Section {
                Picker("Codec", selection: $codec) {
                    ForEach(VideoCodecPreference.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }

                Toggle("HDR", isOn: $hdrEnabled)
                    .disabled(!codec.supportsHDR)

                Toggle("YUV 4:4:4", isOn: $yuv444Enabled)
                    .disabled(!codec.supportsYUV444)

                Picker("Color Range", selection: $colorRange) {
                    ForEach(StreamColorRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
            } header: {
                Text("Quality")
            } footer: {
                Text(qualityFooter)
            }

            Section {
                Picker("Channels", selection: $audio) {
                    ForEach(StreamAudioConfiguration.allCases) { audio in
                        Text(audio.title).tag(audio)
                    }
                }

                Toggle("Play Audio on Host", isOn: $playAudioOnHost)
            } header: {
                Text("Audio")
            } footer: {
                Text("The host's speakers keep playing along with the stream.")
            }

#if !os(visionOS)
            Section {
#if os(iOS)
                Toggle("Touch", isOn: $touchEnabled)

                Picker("Touch Mode", selection: $touchMode) {
                    ForEach(TouchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!touchEnabled)
#endif

                Picker("Mouse Mode", selection: $mouseMode) {
                    ForEach(MouseMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Input")
            } footer: {
                Text(inputFooter)
            }
#endif

            Section {
                Picker("Emulated Controller", selection: $gamepadEmulation) {
                    ForEach(GamepadEmulation.allCases) { emulation in
                        Text(emulation.title).tag(emulation)
                    }
                }

                Toggle("Swap A/B and X/Y", isOn: $gamepadSwapsButtons)

                Toggle("Rumble and Trigger Feedback", isOn: $gamepadFeedback)

#if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    Toggle("Use iPhone for Rumble and Motion", isOn: $gamepadUsesDevice)
                }
#endif
            } header: {
                Text("Controller")
            } footer: {
                Text(gamepadFooter)
            }

            Section {
                NavigationLink("About Starlight") {
                    AboutView()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: resolution) { bitrateKbps = recommendedBitrateKbps }
        .onChange(of: frameRate) { bitrateKbps = recommendedBitrateKbps }
        .onChange(of: codec) {
            if !codec.supportsHDR {
                hdrEnabled = false
            }
            if !codec.supportsYUV444 {
                yuv444Enabled = false
            }
        }
        .navigationTitle("Settings")
        .toolbar(removing: .title)
    }

    private var recommendedBitrateKbps: Int {
        StreamSettings.recommendedBitrateKbps(for: resolution.pixelSize, frameRate: frameRate)
    }

    private var bitrateMbpsRange: ClosedRange<Double> {
        let range = StreamSettings.bitrateRangeKbps
        return Double(range.lowerBound) / 1000...Double(range.upperBound) / 1000
    }

    private var bitrateMbps: Binding<Double> {
        Binding {
            Double(bitrateKbps) / 1000
        } set: {
            bitrateKbps = Int(($0 * 1000).rounded())
        }
    }

    private var qualityFooter: String {
        var notes: [String] = []
        if !codec.isHardwareDecodeSupported {
            notes.append(String(localized: "This device can't hardware-decode \(codec.title), so another codec will be used."))
        }
        notes.append(codec.supportsHDR
            ? String(localized: "HDR requires support from both the host and the display.")
            : String(localized: "H.264 doesn't support HDR."))
        notes.append(codec.supportsYUV444
            ? String(localized: "YUV 4:4:4 uses HEVC for sharper text but needs a higher bitrate. It falls back to 4:2:0 if the host doesn't support it.")
            : String(localized: "YUV 4:4:4 requires HEVC."))
        return notes.joined(separator: "\n")
    }

    private var inputFooter: String {
        var notes: [String] = []
#if os(iOS)
        if touchEnabled {
            switch touchMode {
            case .multiTouch:
                notes.append(String(localized: "Multi-Touch sends touches to the host as they are. Requires a Sunshine host."))
            case .trackpad:
                notes.append(String(localized: "In Trackpad mode, slide one finger to move the pointer, tap to click, and double-tap and hold to drag."))
            case .directTap:
                notes.append(String(localized: "In Direct Tap mode, the pointer goes where your finger lands. Tap to click, touch and drag to drag, and touch and hold to right-click."))
            }
            if touchMode != .multiTouch {
                notes.append(String(localized: "Swipe with two fingers to scroll, tap with two fingers to right-click, and tap with three fingers to middle-click."))
            }
        }
#endif
        switch mouseMode {
        case .remoteCursor:
#if os(macOS)
            notes.append(String(localized: "Remote Cursor captures the mouse, which suits games that use it to look around. Press ⌃⌥⇧Z to release or recapture it."))
#else
            notes.append(String(localized: "Remote Cursor locks the pointer, which suits games that use the mouse to look around."))
#endif
        case .localCursor:
            notes.append(String(localized: "Local Cursor keeps the pointer visible and moves it directly, which suits remote desktop use. Some games don't support it."))
        }
        notes.append(String(localized: "The Command key is kept for shortcuts on this device and isn't sent to the host."))
        return notes.joined(separator: "\n")
    }

    private var gamepadFooter: String {
        var notes: [String] = []
        switch gamepadEmulation {
        case .automatic:
            notes.append(String(localized: "The host emulates the same kind of controller you're using, or picks one itself if it can't tell."))
        case .xbox:
            notes.append(String(localized: "The host emulates an Xbox controller, which works with the most games."))
        case .playStation:
            notes.append(String(localized: "The host emulates a PlayStation controller, so games can use motion and the touchpad."))
        }
        if gamepadSwapsButtons {
            notes.append(String(localized: "Uses Nintendo's layout: A acts as B on the host, and X acts as Y."))
        }
#if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone, gamepadUsesDevice {
            notes.append(String(localized: "For controllers your iPhone clips into, like Backbone or Kishi: if the first controller has no rumble motors or motion sensors, your iPhone fills in."))
        }
#endif
        notes.append(String(localized: "Controller settings take effect the next time you stream."))
        return notes.joined(separator: "\n")
    }

    private static func formatMbps(_ kbps: Int) -> String {
        let mbps = Double(kbps) / 1000
        return "\(mbps.formatted(.number.precision(.fractionLength(0...1)))) Mbps"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
