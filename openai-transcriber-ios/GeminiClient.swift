import Foundation

// MARK: - Gemini クライアント
final class GeminiClient {
    static let shared = GeminiClient()
    private init() {}
    
    /// 現在のプレビュー版モデル ID
    private let modelID = "gemini-2.5-pro-preview-05-06"   // 公開時点の最新 ID を指定
    
    /// テキストを要約して返す
    /// - Parameters:
    ///   - text: 入力テキスト
    ///   - prompt: システム / ユーザープロンプト
    func summarize(text: String, prompt: String) async throws -> String {
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
                "maxOutputTokens": 8192
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120          // タイムアウト 120 秒
        config.waitsForConnectivity = true             // 回線が戻るまで待つ
        let session = URLSession(configuration: config)

        // ここでリクエストを送信
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "GeminiClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "APIエラー: \(status)"]
            )
        }
        
        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return geminiResponse.candidates.first?.content.parts.first?.text
               ?? "要約を生成できませんでした"
    }
}

// MARK: - レスポンス構造体
struct GeminiResponse: Codable {
    let candidates: [Candidate]
}

struct Candidate: Codable {
    let content: Content
}

struct Content: Codable {
    let parts: [Part]
}

struct Part: Codable {
    let text: String
}