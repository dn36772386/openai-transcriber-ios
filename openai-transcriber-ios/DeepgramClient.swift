import Foundation
import UIKit

/// Deepgram 音声文字起こしクライアント
final class DeepgramClient {
    
    // レート制限管理
    private static var lastRequestTime: Date = Date.distantPast
    private static let minRequestInterval: TimeInterval = 0.12 // 120ms = 8.3 req/s
    private static let requestLock = NSLock()
    
    // MARK: - Public API
    /// バックグラウンドセッションを使ってアップロードを開始
    @MainActor
    func transcribeInBackground(url: URL, started: Date) throws {
        
        // レート制限チェック
        Self.requestLock.lock()
        defer { Self.requestLock.unlock() }
        
        let now = Date()
        let timeSinceLastRequest = now.timeIntervalSince(Self.lastRequestTime)
        
        if timeSinceLastRequest < Self.minRequestInterval {
            let waitTime = Self.minRequestInterval - timeSinceLastRequest
            throw NSError(
                domain: "DeepgramClient",
                code: 429,
                userInfo: [NSLocalizedDescriptionKey: "レート制限: \(Int(waitTime * 1000))ms後に再試行してください"]
            )
        }
        
        Self.lastRequestTime = now
        Debug.log("DeepgramQueue ▶︎ Enqueuing background task for:", url.lastPathComponent)

        // ファイルサイズチェック
        let attr  = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attr[.size] as? NSNumber)?.intValue ?? 0
        let maxBytes = 2 * 1024 * 1024 * 1024  // 2GB (Deepgramの制限)
        guard bytes >= 100 && bytes <= maxBytes else {
            throw NSError(domain: "Deepgram", code: -3,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Audio size invalid (\(bytes) bytes) – must be between 100B and 2GB"])
        }

        // 音声データを読み込む
        let audioData = try Data(contentsOf: url)
        
        // 一時ファイルに保存（バックグラウンドセッション用）
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("deepgram_upload_\(UUID().uuidString).wav")
        try audioData.write(to: tempURL)

        // バックグラウンドセッションを取得
        let session = BackgroundSessionManager.shared.backgroundSession

        // リクエストを作成
        let apiKey = try fetchAPIKey()
        var req = URLRequest(
            url: URL(string: "https://api.deepgram.com/v1/listen?model=nova-2&language=ja&punctuate=true&diarize=true&smart_format=true&utterances=true")!
        )
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(mimeType(for: url), forHTTPHeaderField: "Content-Type")

        // アップロードタスクを作成して開始
        let task = session.uploadTask(with: req, fromFile: tempURL)

        // BackgroundSessionManager にタスク情報を登録
        BackgroundSessionManager.shared.registerBackgroundTask(
            taskId: task.taskIdentifier, 
            url: url, 
            startTime: started, 
            tempURL: tempURL,
            apiType: .deepgram  // APIタイプを追加
        )

        Debug.log("🔵 [\(task.taskIdentifier)] Starting Deepgram background upload task for \(url.lastPathComponent)")
        task.resume()
    }

    private func fetchAPIKey() throws -> String {
        guard let key = KeychainHelper.shared.deepgramApiKey(), !key.isEmpty else {
            throw NSError(domain: "DeepgramClient", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Deepgram API キー未設定"])
        }
        return key
    }
    
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/opus"
        case "webm": return "audio/webm"
        default: return "audio/wav"
        }
    }
}

// Deepgramレスポンス構造体
struct DeepgramResponse: Decodable {
    let results: Results
    let metadata: Metadata?
    
    struct Results: Decodable {
        let channels: [Channel]
        let utterances: [Utterance]? // 話者分離された発話
    }
    
    struct Channel: Decodable {
        let alternatives: [Alternative]
    }
    
    struct Alternative: Decodable {
        let transcript: String
        let confidence: Double
        let words: [Word]?
    }
    
    struct Word: Decodable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Double
        let speaker: Int?
    }
    
    struct Utterance: Decodable {
        let start: Double
        let end: Double
        let confidence: Double
        let channel: Int
        let transcript: String
        let speaker: Int?
    }
    
    struct Metadata: Decodable {
        let request_id: String?
        let model_info: ModelInfo?
    }
    
    struct ModelInfo: Decodable {
        let name: String?
        let version: String?
        let arch: String?
    }
}
