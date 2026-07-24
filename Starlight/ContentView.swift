//
//  ContentView.swift
//  Starlight
//
//  Created by Zayrick on 2026/7/11.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
        } detail: {
            EmptyView()
        }
    }
}

#Preview {
    ContentView()
}
