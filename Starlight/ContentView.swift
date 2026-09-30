//
//  ContentView.swift
//  Starlight
//
//  Created by Zayrick on 2026/7/11.
//

import SwiftUI

struct ContentView: View {
    @Environment(HostStore.self) private var hostStore
    @Environment(\.scenePhase) private var scenePhase
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
    }

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
                    Label("设备", systemImage: "desktopcomputer")
                }
                .listRowSeparator(.hidden)

                NavigationLink {
                    AppsView()
                } label: {
                    Label("应用", systemImage: "square.grid.2x2")
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
        }
        .searchable(text: $searchText, prompt: "搜索")
    }
#elseif os(iOS)
    private var mobileContent: some View {
        TabView {
            Tab("设备", systemImage: "desktopcomputer") {
                NavigationStack {
                    DevicesView(searchText: searchText)
                }
            }

            Tab("应用", systemImage: "square.grid.2x2") {
                NavigationStack {
                    AppsView()
                }
            }

            Tab(role: .search) {
                NavigationStack {
                    DevicesView(searchText: searchText)
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索设备")
        .tabViewSearchActivation(.searchTabSelection)
    }
#else
    private var spatialContent: some View {
        TabView {
            Tab("设备", systemImage: "desktopcomputer") {
                NavigationStack {
                    DevicesView(searchText: searchText)
                        .searchable(text: $searchText, prompt: "搜索")
                }
            }

            Tab("应用", systemImage: "square.grid.2x2") {
                NavigationStack {
                    AppsView()
                }
            }
        }
    }
#endif
}

#Preview {
    ContentView()
        .environment(HostStore())
}
