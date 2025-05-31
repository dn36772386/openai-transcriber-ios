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
    @State private var geminiMaxTokens: Int = UserDefaults.standard.integer(forKey: "geminiMaxTokens") == 0 ? 10000 : UserDefaults.standard.integer(forKey: "geminiMaxTokens")
    
    // 要約レベルの圧縮率設定
    @State private var heavySummaryRatio: Int = UserDefaults.standard.integer(forKey: "heavySummaryRatio") == 0 ? 30 : UserDefaults.standard.integer(forKey: "heavySummaryRatio")
    @State private var standardSummaryRatio: Int = UserDefaults.standard.integer(forKey: "standardSummaryRatio") == 0 ? 60 : UserDefaults.standard.integer(forKey: "standardSummaryRatio")
    @State private var lightSummaryRatio: Int = UserDefaults.standard.integer(forKey: "lightSummaryRatio") == 0 ? 80 : UserDefaults.standard.integer(forKey: "lightSummaryRatio")

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
                            Text("最大トークン数（軽い要約時）")
                            Spacer()
                            Text("\(geminiMaxTokens)")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(geminiMaxTokens) },
                            set: { geminiMaxTokens = Int($0) }
                        ), in: 5000...20000, step: 1000)
                        
                        HStack {
                            Text("推奨設定:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("8000") {
                                geminiMaxTokens = 8000
                            }
                            Button("10000") {
                                geminiMaxTokens = 10000
                            }
                            Button("12000") {
                                geminiMaxTokens = 12000
                            }
                        }
                        .font(.caption)
                        
                        // 実際に使用されるトークン数の表示
                        VStack(alignment: .leading, spacing: 4) {
                            Text("実際の使用トークン数:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• しっかり要約: 約\(Int(Double(geminiMaxTokens) * Double(heavySummaryRatio) / 100.0))トークン")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("• 標準的な要約: 約\(Int(Double(geminiMaxTokens) * Double(standardSummaryRatio) / 100.0))トークン")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("• 軽い要約: 約\(geminiMaxTokens)トークン")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)
                    }
                } header: {
                    Text("Gemini設定")
                } footer: {
                    Text("軽い要約時の最大トークン数を設定します。他の要約レベルではこの値に各レベルの割合を掛けた値が使用されます。")
                }
                
                // 要約設定を最下部に移動
                Section {
                    VStack(alignment: .leading, spacing: 15) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("しっかり要約")
                                Spacer()
                                Text("\(heavySummaryRatio)%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(heavySummaryRatio) },
                                set: { heavySummaryRatio = Int($0) }
                            ), in: 10...50, step: 5)
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("標準的な要約")
                                Spacer()
                                Text("\(standardSummaryRatio)%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(standardSummaryRatio) },
                                set: { standardSummaryRatio = Int($0) }
                            ), in: 40...70, step: 5)
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("軽い要約")
                                Spacer()
                                Text("\(lightSummaryRatio)%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(lightSummaryRatio) },
                                set: { lightSummaryRatio = Int($0) }
                            ), in: 70...90, step: 5)
                        }
                    }
                } header: {
                    Text("要約レベル設定")
                } footer: {
                    Text("各要約レベルの圧縮率を設定します")
                }
                
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
                        
                        // 要約レベルの保存
                        UserDefaults.standard.set(heavySummaryRatio, forKey: "heavySummaryRatio")
                        UserDefaults.standard.set(standardSummaryRatio, forKey: "standardSummaryRatio")
                        UserDefaults.standard.set(lightSummaryRatio, forKey: "lightSummaryRatio")
                        
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