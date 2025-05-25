import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var openAIKey = KeychainHelper.shared.apiKey() ?? ""
    @State private var geminiKey = KeychainHelper.shared.geminiApiKey() ?? ""
    @State private var summarizePrompt = UserDefaults.standard.string(forKey: "summarizePrompt") ?? 
        "以下の文章を簡潔に要約してください。重要なポイントを箇条書きで示してください："
    
    var body: some View {
        NavigationView {  // ⭐️ NavigationStackをNavigationViewに変更
            Form {
                Section("OpenAI API") {
                    SecureField("OpenAI APIキー", text: $openAIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onAppear {
                            openAIKey = KeychainHelper.shared.apiKey() ?? ""
                        }
                }
                
                Section("Gemini API") {
                    SecureField("Gemini APIキー", text: $geminiKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onAppear {
                            geminiKey = KeychainHelper.shared.geminiApiKey() ?? ""
                        }
                }
                
                Section {  // ⭐️ iOS 15互換の文法に変更
                    VStack(alignment: .leading) {
                        Text("要約プロンプト")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $summarizePrompt)
                            .frame(minHeight: 100)
                            .padding(4)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(4)
                    }
                } header: {
                    Text("要約設定")
                } footer: {
                    Text("文書を要約する際のプロンプトを設定します")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)  // ⭐️ 追加（オプション）
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        KeychainHelper.shared.save(apiKey: openAIKey.trimmingCharacters(in: .whitespaces))
                        KeychainHelper.shared.saveGeminiKey(geminiKey.trimmingCharacters(in: .whitespaces))
                        UserDefaults.standard.set(summarizePrompt, forKey: "summarizePrompt")
                        dismiss()
                    }
                    .disabled(openAIKey.trimmingCharacters(in: .whitespaces).isEmpty)  // ⭐️ 既存と同じ条件を追加
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}