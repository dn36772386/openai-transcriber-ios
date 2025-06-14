import SwiftUI
import UIKit
import UserNotifications

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
    @Binding var showSummaryOptions: Bool
    @Binding var selectedSummaryLevel: SummaryLevel
    
    @State private var summaryText = "" 
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var summaryTargetHistoryId: UUID? = nil
    @State private var summaryProgress: Double = 0.0
    @State private var isCancelled = false
    @State private var currentTask: Task<Void, Never>?
    @State private var appDidEnterBackground = false
    
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
                            .padding(.horizontal, 16)
                            .padding(.top)
                        
                        Text(summaryText)
                            .font(.system(size: 14))
                            .padding(.horizontal, 16)
                            .textSelection(.enabled)
                        
                        Spacer(minLength: 50)
                    }
                }
            }
            
            Spacer()
            
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
            // バックグラウンド通知を監視
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                if isLoading {
                    appDidEnterBackground = true
                    // バックグラウンドに入ったことをユーザーに通知
                    showBackgroundWarning()
                }
            }
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
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
            getConfirmationDialogTitle(),
            isPresented: $showSummaryOptions,
            titleVisibility: .visible
        ) {
            ForEach(SummaryLevel.allCases, id: \.self) { level in
                Button(action: {
                    selectedSummaryLevel = level
                    // 要約開始時に現在の履歴IDを保存
                    summaryTargetHistoryId = HistoryManager.shared.currentHistoryId
                    isGeneratingSummary = true
                    generateSummary()
                }) {
                    Text(getButtonLabel(for: level))
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(getConfirmationMessage())
        }
        .onAppear {
            // バックグラウンド通知を監視
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                if isLoading {
                    appDidEnterBackground = true
                    // バックグラウンドに入ったことをユーザーに通知
                    showBackgroundWarning()
                }
            }
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
        }
        .onChange(of: HistoryManager.shared.currentHistoryId) { oldId, newId in
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
    
    private func getConfirmationDialogTitle() -> String {
        let charCount = transcriptLines
            .map { $0.text }
            .joined(separator: "\n")
            .count
        return "要約レベルを選択（\(charCount)文字）"
    }
    
    private func getButtonLabel(for level: SummaryLevel) -> String {
        let charCount = transcriptLines
            .map { $0.text }
            .joined(separator: "\n")
            .count
        let ratio = getSummaryRatio(for: level)
        let compressedCount = Int(Double(charCount) * Double(ratio) / 100.0)
        
        return "\(level.rawValue)（約\(compressedCount)文字）"
    }
    
    private func getConfirmationMessage() -> String {
        return "圧縮率を選んでください"
    }
    
    private func getSummaryRatio(for level: SummaryLevel) -> Int {
        switch level {
        case .heavy:
            return UserDefaults.standard.integer(forKey: "heavyCompressionRatio") > 0 
                ? UserDefaults.standard.integer(forKey: "heavyCompressionRatio") 
                : 70
        case .standard:
            return UserDefaults.standard.integer(forKey: "standardCompressionRatio") > 0 
                ? UserDefaults.standard.integer(forKey: "standardCompressionRatio") 
                : 50
        case .light:
            return UserDefaults.standard.integer(forKey: "lightCompressionRatio") > 0 
                ? UserDefaults.standard.integer(forKey: "lightCompressionRatio") 
                : 30
        }
    }
    
    private func getSummaryPrompt(for level: SummaryLevel, ratio: Int) -> String {
        let basePrompt = UserDefaults.standard.string(forKey: "summarizePrompt") ?? 
            "以下の文章を簡潔に要約してください。重要なポイントを箇条書きで示してください："
        
        let ratioInstruction = "\n\n要約は元の文章の約\(ratio)%の長さにまとめてください。"
        
        return basePrompt + ratioInstruction
    }
    
    private func calculateOptimalTokens(text: String, level: SummaryLevel) -> Int {
        let charCount = text.count
        let compressionRatio = Double(getSummaryRatio(for: level)) / 100.0
        
        // 要約後の推定文字数
        let compressedCharCount = Int(Double(charCount) * compressionRatio)
        
        // 日本語は1文字≈0.5トークン
        let outputTokens = compressedCharCount / 2
        
        // Gemini 2.5の思考トークンを考慮（3倍）
        let totalTokens = outputTokens * 3
        
        // 最小6000トークンを保証（思考トークン対策）
        let minTokens = UserDefaults.standard.integer(forKey: "minTokenLimit") > 0
            ? UserDefaults.standard.integer(forKey: "minTokenLimit")
            : 6000
        
        let maxTokens = UserDefaults.standard.integer(forKey: "maxTokenLimit") > 0
            ? UserDefaults.standard.integer(forKey: "maxTokenLimit")
            : 30000
        
        let finalTokens = min(maxTokens, max(minTokens, totalTokens))
        
        print("📊 Token calculation:")
        print("  - Original: \(charCount)文字")
        print("  - Compressed (\(Int(compressionRatio * 100))%): \(compressedCharCount)文字")
        print("  - Output tokens: \(outputTokens)")
        print("  - Min tokens: \(minTokens)")
        print("  - Total allocated: \(finalTokens)")
        
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
        
        // 全ての文字起こしテキストを結合（スピーカー情報を含む）
        let fullText = transcriptLines
            .map { line in
                let timestamp = line.time.formatted(.dateTime.hour().minute().second())
                let speaker = line.speaker != nil ? "[\(line.speaker!)] " : ""
                return "\(timestamp): \(speaker)\(line.text)"
            }
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
        
        // 文字数と圧縮率から最適なトークン数を計算
        let maxTokens = calculateOptimalTokens(text: fullText, level: selectedSummaryLevel)
        
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
            
            // 要約完了通知を送信
            showCompletionNotification(subtitle: subtitle)
            
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
                // エラー通知を送信（バックグラウンドでも動作）
                let errorDescription = getErrorDescription(from: error)
                showErrorNotification(message: errorDescription)
                
                print("❌ Summary generation error: \(error)")
                
                // エラーメッセージをより分かりやすく
                if appDidEnterBackground {
                    errorMessage = "バックグラウンドでの処理中にエラーが発生しました。アプリを開いたまま再度お試しください。"
                    showError = true
                } else if let nsError = error as NSError? {
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
    
    private func showBackgroundWarning() {
        let content = UNMutableNotificationContent()
        content.title = "要約処理中"
        content.body = "アプリを開いたままにしてください。バックグラウンドでは処理が中断される可能性があります。"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "background-warning",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Failed to show background warning: \(error)")
            }
        }
    }
    
    private func showCompletionNotification(subtitle: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "要約完了"
        content.body = subtitle.isEmpty ? "文字起こしの要約が完成しました" : "「\(subtitle)」の要約が完成しました"
        content.sound = .default
        content.categoryIdentifier = "SUMMARY_COMPLETE"
        
        let request = UNNotificationRequest(
            identifier: "summary-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Failed to send summary completion notification: \(error)")
            }
        }
    }
    
    private func showErrorNotification(message: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "要約エラー"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = "SUMMARY_ERROR"
        
        let request = UNNotificationRequest(
            identifier: "summary-error-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Failed to send error notification: \(error)")
            }
        }
    }
    
    private func getErrorDescription(from error: Error) -> String {
        if appDidEnterBackground {
            return "バックグラウンドでの処理中にエラーが発生しました"
        } else if let nsError = error as NSError? {
            if nsError.domain == "GeminiClient" {
                return nsError.localizedDescription
            } else if error.localizedDescription.contains("MAX_TOKENS") {
                return "出力トークン数の上限に達しました"
            } else if error.localizedDescription.contains("timeout") {
                return "タイムアウトしました"
            }
        }
        return "要約生成に失敗しました"
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