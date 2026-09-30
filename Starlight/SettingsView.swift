//
//  SettingsView.swift
//  Starlight
//
//  Created by Codex on 2026/7/24.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        ContentUnavailableView(
            "暂无设置",
            systemImage: "gearshape",
            description: Text("设置内容将在这里显示")
        )
        .navigationTitle("设置")
        .toolbar(removing: .title)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
