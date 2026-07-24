//
//  ContentView.swift
//  Starlight
//
//  Created by Zayrick on 2026/7/11.
//

import SwiftUI

struct ContentView: View {
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink {
                    DevicesView(searchText: $searchText)
                } label: {
                    Label("设备", systemImage: "desktopcomputer")
                }
                .listRowSeparator(.hidden)
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
        } detail: {
            DevicesView(searchText: $searchText)
        }
#if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
#endif
    }
}

#Preview {
    ContentView()
}
