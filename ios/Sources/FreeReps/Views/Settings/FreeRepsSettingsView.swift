import SwiftUI

struct FreeRepsSettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    var body: some View {
        Form {
            Section {
                TextField("https://your-host.example/health", text: $vm.config.endpointURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if let endpointError = vm.endpointError {
                    Text(endpointError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("SyncHealth Endpoint")
            } footer: {
                Text("Only an absolute HTTPS URL is accepted.")
            }

            Section {
                SecureField(
                    vm.hasStoredToken ? "Enter a replacement token" : "Enter X-Health-Token",
                    text: $vm.tokenDraft
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    vm.saveToken()
                } label: {
                    Label(
                        vm.hasStoredToken ? "Replace Token" : "Save Token",
                        systemImage: "key.fill"
                    )
                }
                .disabled(vm.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if vm.hasStoredToken {
                    LabeledContent("Status", value: "Stored in Keychain")
                    Button("Clear Token", role: .destructive) {
                        vm.clearToken()
                    }
                }

                if let tokenStatusMessage = vm.tokenStatusMessage {
                    Text(tokenStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Authentication")
            } footer: {
                Text("The stored token is never displayed or written to app settings.")
            }
        }
        .navigationTitle("SyncHealth Connection")
        .onChange(of: vm.config) { vm.saveConfig() }
    }
}
