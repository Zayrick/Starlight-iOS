//
//  AddDeviceView.swift
//  Starlight
//

import SwiftUI

struct AddDeviceView: View {
    @Environment(HostStore.self) private var hostStore
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @FocusState private var isAddressFocused: Bool

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP Address or Hostname", text: $address)
                        .focused($isAddressFocused)
                        .autocorrectionDisabled()
#if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif
                        .onSubmit(add)
                        .disabled(isAdding)
                } footer: {
                    Text("For example, 192.168.1.10 or 192.168.1.10:47989. The host needs to be running Sunshine or GeForce Experience.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Device")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Add", action: add)
                            .disabled(trimmedAddress.isEmpty)
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 220)
        .onAppear {
            isAddressFocused = true
        }
    }

    private func add() {
        guard !trimmedAddress.isEmpty, !isAdding else { return }
        isAdding = true
        errorMessage = nil

        Task {
            defer { isAdding = false }
            do {
                try await hostStore.addHost(trimmedAddress)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    AddDeviceView()
        .environment(HostStore())
}
