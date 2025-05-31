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
    
    // 圧縮率設定
    @State private var heavyCompressionRatio: Int = UserDefaults.standard.integer(forKey: "heavyCompressionRatio") == 0 ? 70 : UserDefaults.standard.integer(forKey: "heavyCompressionRatio")
    @State private var standardCompressionRatio: Int = UserDefaults.standard.integer(forKey: "standardCompressionRatio") == 0 ? 50 : UserDefaults.standard.integer(forKey: "standardCompressionRatio")
    @State private var lightCompressionRatio: Int = UserDefaults.standard.integer(forKey: "lightCompressionRatio") == 0 ? 30 : UserDefaults.standard.integer(forKey: "lightCompressionRatio")
    
    // トークン制限
    @State private var minTokenLimit: Int = UserDefaults.standard.integer(forKey: "minTokenLimit") == 0 ? 6000 : UserDefaults.standard.integer(forKey: "minTokenLimit")
    @State private var maxTokenLimit: Int = UserDefaults.standard.integer(forKey: "maxTokenLimit") == 0 ? 30000 : UserDefaults.standard.integer(forKey: "maxTokenLimit")

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
                
                // 圧縮率設定
                Section {
                    VStack(alignment: .leading, spacing: 15) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("しっかり要約（詳細を残す）")
                                Spacer()
                                Text("\(heavyCompressionRatio)%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(heavyCompressionRatio) },
                                set: { heavyCompressionRatio = Int($0) }
                            ), in: 60...80, step: 5)
                            Text("議論の流れや詳細が分かる要約")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("標準的な要約（バランス型）")
                                Spacer()
                                Text("\(standardCompressionRatio)%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(standardCompressionRatio) },
                                set: { standardCompressionRatio = Int($0) }
                            ), in: 40...60, step: 5)
                            Text("主要な論点を網羅した要約")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("軽い要約（要点のみ）")
                                Spacer()
                                Text("\(lightCompressionRatio)%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(lightCompressionRatio) },
                                set: { lightCompressionRatio = Int($0) }
                            ), in: 20...40, step: 5)
                            Text("決定事項と要点のみの要約")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("要約の圧縮率設定")
                } footer: {
                    Text("文字起こしの何％に圧縮するかを設定します。長い会議ほど圧縮率の選択が重要になります。")
                }
                
                // トークン制限設定
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最小トークン数")
                            Spacer()
                            Text("\(minTokenLimit)")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(minTokenLimit) },
                            set: { minTokenLimit = Int($0) }
                        ), in: 2000...6000, step: 500)
                        Text("短い会議でも最低限確保するトークン数")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最大トークン数")
                            Spacer()
                            Text("\(maxTokenLimit)")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(maxTokenLimit) },
                            set: { maxTokenLimit = Int($0) }
                        ), in: 20000...50000, step: 2000)
                        Text("コスト制限のための上限値")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("トークン制限")
                } footer: {
                    Text("自動計算されたトークン数の上下限を設定します")
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
                        
                        // 圧縮率の保存
                        UserDefaults.standard.set(heavyCompressionRatio, forKey: "heavyCompressionRatio")
                        UserDefaults.standard.set(standardCompressionRatio, forKey: "standardCompressionRatio")
                        UserDefaults.standard.set(lightCompressionRatio, forKey: "lightCompressionRatio")
                        
                        // トークン制限の保存
                        UserDefaults.standard.set(minTokenLimit, forKey: "minTokenLimit")
                        UserDefaults.standard.set(maxTokenLimit, forKey: "maxTokenLimit")
                        
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