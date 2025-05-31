import SwiftUI

enum SummaryLevel: String, CaseIterable {
    case heavy = "しっかり要約"
    case standard = "標準的な要約"
    case light = "軽い要約"
}

struct SummaryView: View {
    @Binding var transcriptLines: [TranscriptLine]
    @Binding var currentSummary: String?
    @Binding var currentSubtitle: String?
    var onSummaryGenerated: ((String, String) -> Void)?
    @Binding var isGeneratingSummary: Bool
    
    @State private var summaryText = "" 
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showSummaryOptions = false
    @State private var selectedSummaryLevel: SummaryLevel = .standard
    @State private var summaryTargetHistoryId: UUID? = nil
    @State private var summaryProgress: Double = 0.0
    @State private var isCancelled = false
    @State private var currentTask: Task<Void, Never>?
    
    var body: some View {
        VStack(spacing: 0) {
            if summaryText.isEmpty && !isLoading {
                EmptyStateView()
            } else if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    
                    Text("要約を生成中...")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    ProgressView(value: summaryProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .padding(.horizontal, 40)
                    
                    Button("キャンセル") {
                        cancelSummary()
                    }
                    .foregroundColor(.red)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("要約結果")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top)
                        
                        Text(summaryText)
                            .font(.system(size: 14))
                            .padding(.horizontal)
                            .textSelection(.enabled)
                        
                        Spacer(minLength: 50)
                    }
                }
            }
            
            // 要約生成ボタン
            if !transcriptLines.isEmpty {
                Button(action: { showSummaryOptions = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .regular))
                        Text(isLoading ? "生成中..." : "要約を生成")
                            .font(.system(size: 14, weight: .regular))
                    }
                    .foregroundColor(isLoading ? Color.textSecondary : Color.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.border, lineWidth: 1)
                    )
                }
                .disabled(isLoading)
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
        .background(Color.appBackground)
        .alert("エラー", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            // 既存の要約があれば表示
            if let summary = currentSummary {
                summaryText = summary
            }
        }
        .onChange(of: currentSummary) { _, newValue in
            if let summary = newValue {
                summaryText = summary
            }
        }
        .onChange(of: currentSubtitle) { _, newValue in
            // サブタイトルは別途管理
        }
        .confirmationDialog(
            "要約レベルを選択",
            isPresented: $showSummaryOptions,
            titleVisibility: .visible
        ) {
            ForEach(SummaryLevel.allCases, id: \.self) { level in
                Button(level.rawValue) {
                    selectedSummaryLevel = level
                    // 要約開始時に現在の履歴IDを保存
                    summaryTargetHistoryId = HistoryManager.shared.currentHistoryId
                    isGeneratingSummary = true
                    generateSummary()
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("どの程度要約しますか？")
        }
        .onChange(of: HistoryManager.shared.currentHistoryId) { _, newId in
            // 履歴が切り替わったら要約をリセット
            if let item = HistoryManager.shared.historyItems.first(where: { $0.id == newId }) {
                summaryText = item.summary ?? ""
                currentSummary = item.summary
                currentSubtitle = item.subtitle
            }
            if isGeneratingSummary {
                // 要約生成中に履歴が切り替わったらフラグをリセット
                isGeneratingSummary = false
            }
        }
    }
    
    private func getSummaryRatio(for level: SummaryLevel) -> Int {
        switch level {
        case .heavy:
            return UserDefaults.standard.integer(forKey: "heavySummaryRatio") > 0 
                ? UserDefaults.standard.integer(forKey: "heavySummaryRatio") 
                : 30
        case .standard:
            return UserDefaults.standard.integer(forKey: "standardSummaryRatio") > 0 
                ? UserDefaults.standard.integer(forKey: "standardSummaryRatio") 
                : 60
        case .light:
            return UserDefaults.standard.integer(forKey: "lightSummaryRatio") > 0 
                ? UserDefaults.standard.integer(forKey: "lightSummaryRatio") 
                : 80
        }
    }
    
    private func getSummaryPrompt(for level: SummaryLevel, ratio: Int) -> String {
        let basePrompt = UserDefaults.standard.string(forKey: "summarizePrompt") ?? 
            "以下の文章を簡潔に要約してください。重要なポイントを箇条書きで示してください："
        
        let ratioInstruction = "\n\n要約の長さは元の文章の約\(ratio)%程度にしてください。"
        
        return basePrompt + ratioInstruction
    }
    
    private func getMaxTokensForLevel(_ level: SummaryLevel) -> Int {
        // 設定から最大トークン数を取得（デフォルト: 10000）
        let baseMaxTokens = UserDefaults.standard.integer(forKey: "geminiMaxTokens") > 0 
            ? UserDefaults.standard.integer(forKey: "geminiMaxTokens")
            : 10000
        
        // 要約レベルの割合を取得して計算
        let ratio = getSummaryRatio(for: level)
        let calculatedTokens = Int(Double(baseMaxTokens) * Double(ratio) / 100.0)
        
        // 最低2000トークンを確保（思考トークン分を考慮）
        let finalTokens = max(2000, calculatedTokens)
        
        print("📊 Summary tokens calculation - Base: \(baseMaxTokens), Ratio: \(ratio)%, Result: \(finalTokens)")
        return finalTokens
    }
    
    private func generateSummary() {
        isCancelled = false
        summaryProgress = 0.0
        currentTask = Task {
            await performSummary()
        }
    }
    
    private func cancelSummary() {
        isCancelled = true
        currentTask?.cancel()
        isLoading = false
        isGeneratingSummary = false
        summaryProgress = 0.0
        summaryTargetHistoryId = nil
    }
    
    @MainActor
    private func performSummary() async {
        isLoading = true
        
        // 全ての文字起こしテキストを結合
        let fullText = transcriptLines
            .map { "\($0.time.formatted(.dateTime.hour().minute().second())): \($0.text)" }
            .joined(separator: "\n")
        
        // テキストが長すぎる場合の警告
        let estimatedTokens = fullText.count / 4  // 概算
        if estimatedTokens > 60000 {
            print("⚠️ Text might be too long for summarization: ~\(estimatedTokens) tokens")
        }
        
        // 選択されたレベルに応じたプロンプトを生成
        let ratio = getSummaryRatio(for: selectedSummaryLevel)
        let prompt = getSummaryPrompt(for: selectedSummaryLevel, ratio: ratio)
        
        // サブタイトル用のプロンプト
        let subtitlePrompt = "\n\nまた、この内容を表す20文字以内の短いサブタイトルも生成してください。サブタイトルは「サブタイトル：」で始めてください。"
        
        // 要約レベルに応じたトークン数を取得
        let maxTokens = getMaxTokensForLevel(selectedSummaryLevel)
        
        do {
            // プログレス更新（擬似的）
            for i in 1...9 {
                if isCancelled { throw CancellationError() }
                summaryProgress = Double(i) / 10.0
                try await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
            }
            
            let result = try await GeminiClient.shared.summarize(text: fullText, prompt: prompt + subtitlePrompt, maxTokens: maxTokens)
            
            if isCancelled { throw CancellationError() }
            summaryProgress = 1.0
            
            // サブタイトルを抽出
            let lines = result.split(separator: "\n")
            let subtitleLine = lines.first { $0.contains("サブタイトル：") }
            let subtitle = subtitleLine?.replacingOccurrences(of: "サブタイトル：", with: "").trimmingCharacters(in: .whitespaces) ?? ""
            let summary = result.replacingOccurrences(of: subtitleLine ?? "", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            
            summaryText = summary
            currentSummary = summary
            currentSubtitle = subtitle
            
            // 要約生成フラグをリセット
            isGeneratingSummary = false
            
            // 要約結果を正しい履歴に保存
            if let targetId = summaryTargetHistoryId {
                // 対象の履歴を更新（現在の履歴でない場合も正しく更新）
                if let item = HistoryManager.shared.historyItems.first(where: { $0.id == targetId }) {
                    let lines = item.getTranscriptLines(audioStorageDirectory: HistoryManager.shared.audioStorageDirectory)
                    let fullAudioURL = item.getFullAudioURL(audioStorageDirectory: HistoryManager.shared.audioStorageDirectory)
                    HistoryManager.shared.updateHistoryItem(id: targetId, lines: lines, fullAudioURL: fullAudioURL, summary: summary, subtitle: subtitle)
                }
            }
            onSummaryGenerated?(summary, subtitle)
        } catch {
            if error is CancellationError {
                print("ℹ️ Summary generation cancelled")
            } else {
                print("❌ Summary generation error: \(error)")
                
                // エラーメッセージをより分かりやすく
                if let nsError = error as NSError? {
                    if nsError.domain == "GeminiClient" {
                        errorMessage = nsError.localizedDescription
                    } else if error.localizedDescription.contains("keyNotFound") {
                        errorMessage = "APIレスポンスの形式が変更されました。アプリの更新が必要です。"
                    } else if error.localizedDescription.contains("MAX_TOKENS") {
                        errorMessage = nsError.localizedDescription
                    } else if error.localizedDescription.contains("timeout") {
                        errorMessage = "タイムアウトしました。ネットワーク接続を確認してください。"
                    } else {
                        errorMessage = "要約生成エラー: \(error.localizedDescription)"
                    }
                } else {
                    errorMessage = "要約生成エラー: \(error.localizedDescription)"
                }
                
                showError = true
            }
            isGeneratingSummary = false
        }
        
        isLoading = false
        summaryTargetHistoryId = nil
        summaryProgress = 0.0
        currentTask = nil
    }
}

// キャンセルエラー
struct CancellationError: Error {
    var localizedDescription: String {
        "キャンセルされました"
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("要約がありません")
                .font(.headline)
                .foregroundColor(.gray)
            
            Text("文字起こしを完了してから\n要約を生成してください")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("要約を生成中...")
                .font(.headline)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}