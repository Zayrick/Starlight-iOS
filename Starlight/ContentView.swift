//
//  ContentView.swift
//  Starlight
//
//  Created by Zayrick on 2026/7/11.
//

import SwiftUI

struct ContentView: View {
    @Environment(HostStore.self) private var hostStore
    @Environment(StreamController.self) private var streamController
    @Environment(\.scenePhase) private var scenePhase
#if os(macOS) || os(visionOS)
    @Environment(\.openWindow) private var openWindow
#endif
    @State private var searchText = ""

    var body: some View {
        platformContent
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Only scan and poll hosts while the app is in the foreground
                if phase == .active {
                    hostStore.start()
                } else if phase == .background {
                    hostStore.stop()
                }
            }
#if os(iOS)
            .landscapeCover(item: activeSession) { session in
                // Hosted by UIKit, so the environment doesn't carry over
                StreamView(session: session)
                    .environment(streamController)
            }
#else
            .onChange(of: streamController.session?.id) { _, id in
                if id != nil {
                    openWindow(id: StreamWindow.id)
                }
            }
#endif
    }

#if os(iOS)
    private var activeSession: Binding<StreamSession?> {
        Binding {
            streamController.session
        } set: { session in
            if session == nil {
                streamController.close()
            }
        }
    }
#endif

    @ViewBuilder
    private var platformContent: some View {
#if os(macOS)
        macContent
#elseif os(iOS)
        mobileContent
#else
        spatialContent
#endif
    }

#if os(macOS)
    private var macContent: some View {
        NavigationSplitView {
            List {
                NavigationLink {
                    searchableDevices
                } label: {
                    Label("Devices", systemImage: "desktopcomputer")
                }
                .listRowSeparator(.hidden)

                NavigationLink {
                    NavigationStack {
                        SettingsView()
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .listRowSeparator(.hidden)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            searchableDevices
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var searchableDevices: some View {
        NavigationStack {
            DevicesView(searchText: searchText)
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        }
    }
#elseif os(iOS)
    private var mobileContent: some View {
        TabView {
            Tab("Devices", systemImage: "desktopcomputer") {
                NavigationStack {
                    DevicesView(searchText: "")
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                }
            }

            Tab(role: .search) {
                NavigationStack {
                    DevicesView(searchText: searchText)
                }
                // Scoped to the search tab so the devices tab doesn't get its own field
                .searchable(text: $searchText, prompt: "Search Devices")
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
    }
#else
    private var spatialContent: some View {
        TabView {
            Tab("Devices", systemImage: "desktopcomputer") {
                NavigationStack {
                    DevicesView(searchText: searchText)
                        .searchable(text: $searchText, prompt: "Search")
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
#endif
}

#Preview {
    ContentView()
        .environment(HostStore())
        .environment(StreamController())
}
