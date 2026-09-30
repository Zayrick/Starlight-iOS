//
//  PairingView.swift
//  Starlight
//

import SwiftUI

private struct PairingView: View {
    let pairing: HostStore.Pairing

    @Environment(HostStore.self) private var hostStore

    private var hostName: String {
        hostStore.host(id: pairing.hostID)?.name ?? ""
    }

    var body: some View {
        VStack(spacing: 20) {
            if let errorMessage = pairing.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                Text("配对失败")
                    .font(.title2.weight(.semibold))

                Text(errorMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("取消", role: .cancel) {
                        hostStore.cancelPairing()
                    }
                    Button("重试") {
                        hostStore.startPairing(hostID: pairing.hostID)
                    }
                    .prominentButtonStyle()
                }
            } else {
                Text("与“\(hostName)”配对")
                    .font(.title2.weight(.semibold))

                Text(pairing.pin)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(12)
                    .textSelection(.enabled)
                    .accessibilityLabel("配对码 \(pairing.pin.map(String.init).joined(separator: " "))")

                Text("请在主机上打开 Sunshine 网页管理界面的 PIN 页面，输入上方的配对码。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                ProgressView()

                Button("取消", role: .cancel) {
                    hostStore.cancelPairing()
                }
            }
        }
        .padding(32)
        .frame(minWidth: 340, maxWidth: 440)
        .interactiveDismissDisabled(pairing.errorMessage == nil)
    }
}

private struct PairingSheet: ViewModifier {
    let hostID: String?

    @Environment(HostStore.self) private var hostStore

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { hostID != nil && hostStore.pairing?.hostID == hostID },
            set: { isPresented in
                if !isPresented {
                    hostStore.cancelPairing()
                }
            }
        )) {
            if let pairing = hostStore.pairing {
                PairingView(pairing: pairing)
            }
        }
    }
}

extension View {
    /// Shows the PIN while `hostID` is being paired; dismissing cancels pairing.
    func pairingSheet(hostID: String?) -> some View {
        modifier(PairingSheet(hostID: hostID))
    }

    @ViewBuilder
    func prominentButtonStyle() -> some View {
#if os(visionOS)
        buttonStyle(.borderedProminent)
#else
        buttonStyle(.glassProminent)
#endif
    }
}
