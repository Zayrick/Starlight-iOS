//
//  AboutView.swift
//  Starlight
//

import SwiftUI

struct AboutView: View {
    static let sourceURL = URL(string: "https://github.com/Zayrick/Starlight-iOS")!
    static let privacyURL = URL(string: "https://github.com/Zayrick/Starlight-iOS/blob/main/PRIVACY.md")!

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
                    Text("Version \(Self.version)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Stream games and desktops from your computer to iPhone, iPad, Mac, and Apple Vision Pro. Works with Sunshine and NVIDIA GameStream hosts.")
            }

            Section {
                Link(destination: Self.sourceURL) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }

                Link(destination: Self.privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }

                NavigationLink {
                    LicenseTextView(title: "GNU GPL v3", resource: "GPL-3.0")
                } label: {
                    Label("License", systemImage: "doc.text")
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text("Starlight is free software released under the GNU General Public License v3 (GPLv3). You can obtain, modify, and redistribute its source code under the terms of that license. It comes with no warranty.")
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
                Text("Acknowledgements")
            } footer: {
                Text("The streaming protocol is based on moonlight-common-c from the Moonlight project. Starlight is an independent project and isn't affiliated with Moonlight, NVIDIA, or Sunshine.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
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
