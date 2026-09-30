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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(hostStore)
        }
#if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
#endif
    }
}
