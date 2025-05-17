import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = KeychainHelper.shared.apiKey() ?? ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("OpenAI APIキー", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        KeychainHelper.shared.save(apiKey: keyInput.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }.disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
