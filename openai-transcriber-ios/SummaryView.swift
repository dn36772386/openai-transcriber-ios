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
    
    var body: some View {
        VStack(spacing: 0) {
            if summaryText.isEmpty && !isLoading {
                EmptyStateView()
            } else if isLoading {
                LoadingView()
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
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(isLoading ? "要約生成中..." : "要約を生成")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accent)
                    .cornerRadius(25)
                }
                .disabled(isLoading)
                .padding()
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
            summaryText = ""
            currentSummary = nil
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
    
    private func generateSummary() {
        Task {
            await performSummary()
        }
    }
    
    @MainActor
    private func performSummary() async {
        isLoading = true
        
        // 全ての文字起こしテキストを結合
        let fullText = transcriptLines
            .map { "\($0.time.formatted(.dateTime.hour().minute().second())): \($0.text)" }
            .joined(separator: "\n")
        
        // 選択されたレベルに応じたプロンプトを生成
        let ratio = getSummaryRatio(for: selectedSummaryLevel)
        let prompt = getSummaryPrompt(for: selectedSummaryLevel, ratio: ratio)
        
        // サブタイトル用のプロンプト
        let subtitlePrompt = "\n\nまた、この内容を表す20文字以内の短いサブタイトルも生成してください。サブタイトルは「サブタイトル：」で始めてください。"
        
        do {
            let result = try await GeminiClient.shared.summarize(text: fullText, prompt: prompt + subtitlePrompt)
            
            // サブタイトルを抽出
            let lines = result.split(separator: "\n")
            let subtitleLine = lines.first { $0.contains("サブタイトル：") }
            let subtitle = subtitleLine?.replacingOccurrences(of: "サブタイトル：", with: "").trimmingCharacters(in: .whitespaces) ?? ""
            let summary = result.replacingOccurrences(of: subtitleLine ?? "", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            
            summaryText = summary
            currentSummary = summary
            currentSubtitle = subtitle
            
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
            errorMessage = error.localizedDescription
            showError = true
        }
        
        isLoading = false
        summaryTargetHistoryId = nil
        isGeneratingSummary = false
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