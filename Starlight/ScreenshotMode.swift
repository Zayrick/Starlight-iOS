//
//  ScreenshotMode.swift
//  Starlight
//
//  Sample hosts, apps and a stream for the App Store screenshots. Turned on
//  by the `-ScreenshotMode` launch argument in debug builds, it stands in for
//  the network so the UI tests can capture every screen without a real host.
//

import SwiftUI

enum ScreenshotMode {
#if DEBUG
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-ScreenshotMode")
#else
    static let isEnabled = false
#endif

    static let pin = "4831"

    /// One host in each state a device card can show.
    static var hosts: [StreamHost] {
        let apps = (1...9).map {
            StreamApp(id: "\($0)", name: String(localized: "App \($0)"), isHDRSupported: true)
        }
        return [
            host("screenshot.gaming", String(localized: "Gaming PC"), "192.168.1.20", apps: apps, runningAppID: "1"),
            host("screenshot.livingRoom", String(localized: "Living Room PC"), "192.168.1.32", apps: apps),
            host("screenshot.workstation", String(localized: "Workstation"), "192.168.1.45", pairState: .unpaired),
            host("screenshot.office", String(localized: "Office PC"), "10.0.0.8", status: .offline, pairState: .unknown),
        ]
    }

    private static func host(
        _ id: String,
        _ name: String,
        _ address: String,
        status: StreamHost.Status = .online,
        pairState: StreamHost.PairState = .paired,
        apps: [StreamApp] = [],
        runningAppID: String? = nil
    ) -> StreamHost {
        var host = StreamHost(id: id, name: name)
        host.localAddress = HostAddress(host: address)
        host.status = status
        host.pairState = pairState
        host.apps = apps
        host.currentGameID = runningAppID
        return host
    }

    static let statistics = StreamStatistics(
        width: 2560,
        height: 1440,
        format: .hevcMain10,
        frameRate: 120,
        bitsPerSecond: 48_600_000,
        lossRate: 0,
        hostLatencyMs: 2.4,
        roundTripTimeMs: 3
    )

    private static var artworkCache: [String: CGImage] = [:]

    /// Placeholder box art with the app's name in the middle.
    static func artwork(for app: StreamApp) -> CGImage? {
        if let image = artworkCache[app.id] {
            return image
        }
        let hue = Double(Int(app.id) ?? 0) * 0.11
        let renderer = ImageRenderer(content: ScreenshotPlaceholder(title: app.name, hue: hue)
            .frame(width: 300, height: 400))
        renderer.scale = 2
        let image = renderer.cgImage
        artworkCache[app.id] = image
        return image
    }
}

/// Stands in for the host's picture while streaming.
struct ScreenshotStreamPicture: View {
    let appName: String

    var body: some View {
        ScreenshotPlaceholder(title: String(localized: "Stream Picture"), subtitle: appName, hue: 0.62)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

private struct ScreenshotPlaceholder: View {
    let title: String
    var subtitle: String?
    let hue: Double

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.85),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.title3.weight(.medium))
                        .opacity(0.7)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding()
        }
    }
}
