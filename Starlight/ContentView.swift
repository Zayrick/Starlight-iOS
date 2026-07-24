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
                Label("设备", systemImage: "desktopcomputer")
                    .listRowSeparator(.hidden)
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
        } detail: {
            Color.clear
                .toolbar {
                    ToolbarSpacer(.flexible)

                    ToolbarItem {
                        Button("添加", systemImage: "plus") {}
                    }
                }
                .toolbar(removing: .title)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索")
#if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
#endif
    }
}

#Preview {
    ContentView()
}
