import Foundation
import UIKit

// MARK: - Gemini クライアント
final class GeminiClient {
    static let shared = GeminiClient()
    private init() {}
    
    /// 現在のプレビュー版モデル ID
    private let modelID = "gemini-2.5-pro-preview-05-06"   // 公開時点の最新 ID を指定
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    /// テキストを要約して返す
    /// - Parameters:
    ///   - text: 入力テキスト
    ///   - prompt: システム / ユーザープロンプト
    func summarize(text: String, prompt: String, maxTokens: Int? = nil) async throws -> String {
        
        // バックグラウンドタスクを開始
        backgroundTask = await UIApplication.shared.beginBackgroundTask(withName: "GeminiSummarization") {
            // タイムアウト時の処理
            print("⚠️ Background task expired")
            self.endBackgroundTask()
        }
        
        defer {
            // 処理完了時にバックグラウンドタスクを終了
            endBackgroundTask()
        }
        
        guard let apiKey = KeychainHelper.shared.geminiApiKey() else {
            throw NSError(
                domain: "GeminiClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Gemini APIキーが設定されていません"]
            )
        }
        
        // エンドポイントを 2.5 Pro 用に変更
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw NSError(
                domain: "GeminiClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "URLの生成に失敗しました"]
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 2.5 Pro は最大 65 535 トークンまで出力可。必要に応じて調整
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "\(prompt)\n\n\(text)"]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.7,
                "maxOutputTokens": maxTokens ?? 8192,
                "candidateCount": 1,
                "topK": 40,
                "topP": 0.95
            ]
        ]
        
        print("📝 Gemini API Request - Max Output Tokens: \(maxTokens ?? 8192)")
        
        // 入力テキストが長すぎる場合の警告
        let estimatedInputTokens = text.count / 4  // 概算
        if estimatedInputTokens > 50000 {
            print("⚠️ Text might be too long for summarization: ~\(estimatedInputTokens) tokens")
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // バックグラウンド対応の設定
        let config = URLSessionConfiguration.default    // ephemeralからdefaultに変更
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300         // リソースタイムアウトを追加
        config.allowsCellularAccess = true              // セルラー接続を許可
        config.shouldUseExtendedBackgroundIdleMode = true  // バックグラウンドモードを有効化
        config.sessionSendsLaunchEvents = false         // バックグラウンド起動は不要
        config.waitsForConnectivity = true             // 回線が戻るまで待つ
        let session = URLSession(configuration: config)

        // ここでリクエストを送信
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
            print("❌ Gemini API Error - Status: \(status)")
            print("❌ Error Body: \(errorBody)")
            
            // 詳細なエラーメッセージ
            var errorMessage = "APIエラー: \(status)"
            if status == 400 {
                errorMessage = "リクエストが不正です。文章が長すぎる可能性があります。"
            } else if status == 401 {
                errorMessage = "認証エラー: APIキーを確認してください"
            } else if status == 429 {
                errorMessage = "レート制限: しばらく待ってから再試行してください"
            } else if status == 500 {
                errorMessage = "サーバーエラー: しばらく待ってから再試行してください"
            }
            
            throw NSError(
                domain: "GeminiClient",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage,
                    "statusCode": status,
                    "responseBody": errorBody
                ]
            )
        }
        
        // デバッグ用にレスポンスを出力
        if let jsonString = String(data: data, encoding: .utf8) {
            print("📝 Gemini API Response: \(jsonString.prefix(500))...")
        }
        
        do {
            let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            // 使用トークン情報をログ出力
            if let usage = geminiResponse.usageMetadata {
                print("📊 Token Usage - Prompt: \(usage.promptTokenCount ?? 0), Total: \(usage.totalTokenCount ?? 0), Thoughts: \(usage.thoughtsTokenCount ?? 0)")
            }
            
            // 最初の候補を取得
            guard let firstCandidate = geminiResponse.candidates.first else {
                throw NSError(
                    domain: "GeminiClient",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "レスポンスに候補が含まれていません"]
                )
            }
            
            // finishReasonをチェック
            if let finishReason = firstCandidate.finishReason {
                switch finishReason {
                case "MAX_TOKENS":
                    throw NSError(
                        domain: "GeminiClient",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "出力トークン数の上限に達しました。要約レベルを『軽い要約』に変更するか、設定で最大トークン数を増やしてください。"]
                    )
                case "SAFETY":
                    throw NSError(
                        domain: "GeminiClient",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "安全性フィルターによりブロックされました"]
                    )
                default:
                    break
                }
            }
            
            return firstCandidate.content.parts?.first?.text
                   ?? "要約を生成できませんでした"
        } catch {
            print("❌ Decoding error: \(error)")
            // フォールバックとして別の構造を試す
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let content = firstCandidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                return text
            }
            throw error
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

// MARK: - レスポンス構造体
struct GeminiResponse: Codable {
    let candidates: [Candidate]
    let promptFeedback: PromptFeedback?
    let usageMetadata: UsageMetadata?
    
    struct PromptFeedback: Codable {
        let safetyRatings: [SafetyRating]?
    }
    
    struct SafetyRating: Codable {
        let category: String?
        let probability: String?
    }
    
    struct UsageMetadata: Codable {
        let promptTokenCount: Int?
        let totalTokenCount: Int?
        let thoughtsTokenCount: Int?
    }
}

struct Candidate: Codable {
    let content: Content
    let finishReason: String?
    let index: Int?
    let safetyRatings: [GeminiResponse.SafetyRating]?
}

struct Content: Codable {
    let parts: [Part]?
    let role: String?
}

struct Part: Codable {
    let text: String?
}