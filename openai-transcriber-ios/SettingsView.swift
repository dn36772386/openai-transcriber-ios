import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = KeychainHelper.shared.apiKey() ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("OpenAI APIキー", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onAppear {   // ← 画面を開くたび最新を反映
                            keyInput = KeychainHelper.shared.apiKey() ?? ""
                        }
                } footer: {
                    Text("鍵は iOS の Keychain に安全に保存されます。")
                }
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
