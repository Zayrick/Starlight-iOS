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

    var body: some View {
        Form {
            Section {
                Picker("分辨率", selection: $resolution) {
                    ForEach(StreamResolution.availableCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }

                Picker("帧率", selection: $frameRate) {
                    ForEach(StreamSettings.frameRates, id: \.self) { fps in
                        Text("\(fps) FPS").tag(fps)
                    }
                }

                VStack(alignment: .leading) {
                    LabeledContent("码率", value: Self.formatMbps(bitrateKbps))
                    Slider(value: bitrateMbps, in: bitrateMbpsRange, step: 0.5)
                }
            } header: {
                Text("视频")
            } footer: {
                Text("推荐码率 \(Self.formatMbps(recommendedBitrateKbps))，更改分辨率或帧率时会自动重设。")
            }

            Section {
                Picker("编码偏好", selection: $codec) {
                    ForEach(VideoCodecPreference.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }

                Toggle("HDR", isOn: $hdrEnabled)
                    .disabled(!codec.supportsHDR)

                Toggle("YUV 4:4:4", isOn: $yuv444Enabled)
                    .disabled(!codec.supportsYUV444)

                Picker("色彩范围", selection: $colorRange) {
                    ForEach(StreamColorRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
            } header: {
                Text("画质")
            } footer: {
                Text(qualityFooter)
            }

            Section("音频") {
                Picker("声道", selection: $audio) {
                    ForEach(StreamAudioConfiguration.allCases) { audio in
                        Text(audio.title).tag(audio)
                    }
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
        .navigationTitle("设置")
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
            notes.append("此设备不支持 \(codec.title) 硬件解码，串流时将回退到其他编码。")
        }
        notes.append(codec.supportsHDR ? "HDR 需要主机和显示器同时支持。" : "H.264 不支持 HDR。")
        notes.append(codec.supportsYUV444
            ? "YUV 4:4:4 使用 HEVC 编码，文字更清晰但需要更高码率，主机不支持时会回退到 4:2:0。"
            : "YUV 4:4:4 仅支持 HEVC 编码。")
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
