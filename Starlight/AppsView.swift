//
//  AppsView.swift
//  Starlight
//
//  Created by Codex on 2026/7/24.
//

import SwiftUI

struct AppsView: View {
    var body: some View {
        ContentUnavailableView(
            "暂无应用",
            systemImage: "square.grid.2x2",
            description: Text("应用内容将在这里显示")
        )
        .navigationTitle("应用")
        .toolbar(removing: .title)
    }
}

#Preview {
    NavigationStack {
        AppsView()
    }
}
