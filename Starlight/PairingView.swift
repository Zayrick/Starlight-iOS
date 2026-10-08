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

                Text("Pairing Failed")
                    .font(.title2.weight(.semibold))

                Text(errorMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Cancel", role: .cancel) {
                        hostStore.cancelPairing()
                    }
                    Button("Try Again") {
                        hostStore.startPairing(hostID: pairing.hostID)
                    }
                    .prominentButtonStyle()
                }
            } else {
                Text("Pair with “\(hostName)”")
                    .font(.title2.weight(.semibold))

                Text(pairing.pin)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(12)
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(pairing.pin.map(String.init).joined(separator: " "))")

                Text("On the host, open the PIN page in the Sunshine web UI and enter the code above.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                ProgressView()

                Button("Cancel", role: .cancel) {
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
