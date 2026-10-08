//
//  StarlightApp.swift
//  Starlight
//
//  Created by Zayrick on 2026/7/11.
//

import SwiftUI

@main
struct StarlightApp: App {
    @State private var hostStore = HostStore()
    @State private var streamController = StreamController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hostStore)
                .environment(streamController)
        }
#if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
#endif

#if os(macOS) || os(visionOS)
        WindowGroup("Stream", id: StreamWindow.id) {
            StreamWindow()
                .environment(streamController)
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
#endif
#endif
    }
}

#if os(macOS) || os(visionOS)
/// Shows the active stream in its own window, which closes with the stream.
struct StreamWindow: View {
    static let id = "stream"

    @Environment(StreamController.self) private var streamController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = streamController.session {
                StreamView(session: session)
                    .navigationTitle(session.app.name)
            } else {
                Color.black
            }
        }
        .onChange(of: streamController.session == nil, initial: true) { _, isEmpty in
            if isEmpty {
                dismissWindow(id: Self.id)
            }
        }
        .onDisappear {
            // Closing the window ends the stream
            streamController.close()
        }
    }
}
#endif
