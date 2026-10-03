//
//  AboutView.swift
//  Starlight
//

import SwiftUI

struct AboutView: View {
    static let sourceURL = URL(string: "https://github.com/Zayrick/Starlight-iOS")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .padding(.bottom, 6)
                        .accessibilityHidden(true)
                    Text("Starlight")
                        .font(.title.bold())
                    Text("版本 \(Self.version)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } footer: {
                Text("把电脑上的游戏和桌面串流到 iPhone、iPad、Mac 和 Apple Vision Pro，兼容 Sunshine 与 NVIDIA GameStream 主机。")
            }

            Section {
                Link(destination: Self.sourceURL) {
                    Label("源代码", systemImage: "chevron.left.forwardslash.chevron.right")
                }

                NavigationLink {
                    LicenseTextView(title: "GNU GPL v3", resource: "GPL-3.0")
                } label: {
                    Label("许可证", systemImage: "doc.text")
                }
            } header: {
                Text("开源")
            } footer: {
                Text("Starlight 是自由软件，以 GNU 通用公共许可证第 3 版（GPLv3）发布。你可以在该许可证的条款下获取、修改和再分发它的源代码。本软件不提供任何担保。")
            }

            Section {
                ForEach(Acknowledgement.all) { item in
                    NavigationLink {
                        LicenseTextView(title: item.name, resource: item.resource)
                    } label: {
                        LabeledContent(item.name, value: item.license)
                    }
                }
            } header: {
                Text("致谢")
            } footer: {
                Text("串流协议基于 Moonlight 项目的 moonlight-common-c。Starlight 是独立项目，与 Moonlight、NVIDIA 和 Sunshine 没有关联。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("关于")
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct Acknowledgement: Identifiable {
    let name: String
    let license: String
    let resource: String

    var id: String { name }

    static let all = [
        Acknowledgement(name: "moonlight-common-c", license: "GPLv3", resource: "GPL-3.0"),
        Acknowledgement(name: "ENet", license: "MIT", resource: "ENet"),
        Acknowledgement(name: "nanors", license: "MIT", resource: "nanors"),
        Acknowledgement(name: "Opus", license: "BSD", resource: "Opus"),
    ]
}

private struct LicenseTextView: View {
    let title: String
    let resource: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
