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
                    TextField("IP 地址或主机名", text: $address)
                        .focused($isAddressFocused)
                        .autocorrectionDisabled()
#if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
#endif
                        .onSubmit(add)
                        .disabled(isAdding)
                } footer: {
                    Text("例如 192.168.1.10 或 192.168.1.10:47989。主机需要运行 Sunshine 或 GeForce Experience。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加设备")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("添加", action: add)
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
