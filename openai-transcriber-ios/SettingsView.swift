import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var openAIKey = KeychainHelper.shared.apiKey() ?? ""
    @State private var geminiKey = KeychainHelper.shared.geminiApiKey() ?? ""
    @State private var summarizePrompt = UserDefaults.standard.string(forKey: "summarizePrompt") ?? 
        "以下の文章を簡潔に要約してください。重要なポイントを箇条書きで示してください："
    
    // 無音設定パラメーター
    @State private var silenceThreshold: Float = UserDefaults.standard.float(forKey: "silenceThreshold") == 0 ? 0.01 : UserDefaults.standard.float(forKey: "silenceThreshold")
    @State private var silenceWindow: Double = UserDefaults.standard.double(forKey: "silenceWindow") == 0 ? 0.5 : UserDefaults.standard.double(forKey: "silenceWindow")
    @State private var minSegmentDuration: Double = UserDefaults.standard.double(forKey: "minSegmentDuration") == 0 ? 0.5 : UserDefaults.standard.double(forKey: "minSegmentDuration")
    @State private var geminiMaxTokens: Int = UserDefaults.standard.integer(forKey: "geminiMaxTokens") == 0 ? 8192 : UserDefaults.standard.integer(forKey: "geminiMaxTokens")

    var body: some View {
        NavigationView {
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
                
                // 録音設定セクション
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("無音判定閾値")
                            Spacer()
                            Text(String(format: "%.3f", silenceThreshold))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $silenceThreshold, in: 0.001...0.05, step: 0.001)
                        Text("音声の大きさの閾値（小さいほど敏感）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("無音判定時間")
                            Spacer()
                            Text(String(format: "%.1f秒", silenceWindow))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $silenceWindow, in: 0.3...2.0, step: 0.1)
                        Text("この時間無音が続くとセグメントを区切る")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最小セグメント長")
                            Spacer()
                            Text(String(format: "%.1f秒", minSegmentDuration))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $minSegmentDuration, in: 0.3...3.0, step: 0.1)
                        Text("これより短いセグメントは破棄される")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    Button("デフォルトに戻す") {
                        silenceThreshold = 0.01
                        silenceWindow = 0.5
                        minSegmentDuration = 0.5
                    }
                    .foregroundColor(.accentColor)
                    
                } header: {
                    Text("録音設定（自動モード）")
                } footer: {
                    Text("自動モードでの音声区切りの設定を調整します。マニュアルモードでは適用されません。")
                }
                
                // Gemini設定
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最大トークン数")
                            Spacer()
                            Text("\(geminiMaxTokens)")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(geminiMaxTokens) },
                            set: { geminiMaxTokens = Int($0) }
                        ), in: 1024...65535, step: 1024)
                    }
                } header: {
                    Text("Gemini設定")
                } footer: {
                    Text("要約生成時の最大出力トークン数を設定します（1024〜65535）")
                }
                
                // 要約設定を最下部に移動
                Section {
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // APIキーの保存
                        KeychainHelper.shared.save(apiKey: openAIKey.trimmingCharacters(in: .whitespaces))
                        KeychainHelper.shared.saveGeminiKey(geminiKey.trimmingCharacters(in: .whitespaces))
                        
                        // プロンプトの保存
                        UserDefaults.standard.set(summarizePrompt, forKey: "summarizePrompt")
                        
                        // 録音設定の保存
                        UserDefaults.standard.set(silenceThreshold, forKey: "silenceThreshold")
                        UserDefaults.standard.set(silenceWindow, forKey: "silenceWindow")
                        UserDefaults.standard.set(minSegmentDuration, forKey: "minSegmentDuration")
                        UserDefaults.standard.set(geminiMaxTokens, forKey: "geminiMaxTokens")
                        
                        dismiss()
                    }
                    .disabled(openAIKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}