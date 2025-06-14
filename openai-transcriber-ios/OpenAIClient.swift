import Foundation
import UIKit

/// OpenAI 音声文字起こしクライアント
///
/// * Keychain から API キーを取得 → Bearer 認証
/// * multipart/form-data で音声ファイルをアップロード
/// * 1 クラス = 1 エンドポイントのシンプル実装
final class OpenAIClient {

    // レート制限管理（指数バックオフ対応）
    private static var lastRequestTime: Date = Date.distantPast
    private static let minRequestInterval: TimeInterval = 0.12 // 120ms = 8.3 req/s
    private static let requestLock = NSLock()
    private static var retryAttempts: [String: Int] = [:]
    private static let maxRetryAttempts = 5
    
    // MARK: - Public API
    /// バックグラウンドセッションを使ってアップロードを開始 (戻り値なし)
    /// - Parameters:
    ///   - url: 音声ファイルのURL
    ///   - started: セグメントの開始時刻
    ///   - previousTranscript: 直前のセグメントの文字起こし結果（オプション）
    @MainActor
    func transcribeInBackground(url: URL, started: Date, previousTranscript: String? = nil) throws {
        
        // レート制限チェック
        Self.requestLock.lock()
        defer { Self.requestLock.unlock() }
        
        let now = Date()
        let timeSinceLastRequest = now.timeIntervalSince(Self.lastRequestTime)
        
        if timeSinceLastRequest < Self.minRequestInterval {
            let waitTime = Self.minRequestInterval - timeSinceLastRequest
            
            // Check if we should apply exponential backoff
            let (shouldRetry, backoffDelay) = Self.shouldRetryWithBackoff(url: url)
            if shouldRetry {
                let totalDelay = max(waitTime, backoffDelay)
                throw NSError(
                    domain: "OpenAIClient",
                    code: 429,
                    userInfo: [NSLocalizedDescriptionKey: "レート制限: \(Int(totalDelay * 1000))ms後に再試行してください（指数バックオフ適用）"]
                )
            } else {
                throw NSError(
                    domain: "OpenAIClient",
                    code: 429,
                    userInfo: [NSLocalizedDescriptionKey: "最大リトライ回数に達しました"]
                )
            }
        } else {
            // Reset retry count on successful timing
            Self.resetRetryCount(for: url)
        }
        
        Self.lastRequestTime = now
        Debug.log("WhisperQueue ▶︎ Enqueuing background task for:", url.lastPathComponent)

        // ── 0 byte／極小ファイルは送信しない ─────────────────────
        let attr  = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attr[.size] as? NSNumber)?.intValue ?? 0
        let maxBytes = 25 * 1024 * 1024  // 25MB
        guard bytes >= 4_096 && bytes <= maxBytes else {
            throw NSError(domain: "Whisper", code: -3,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Audio size invalid (\(bytes) bytes) – must be between 4KB and 25MB"])
        }

        // ── multipart/form-data を構築 ──────────────────────────────
        let boundary = "Boundary-\(UUID().uuidString)"
        var form = MultipartFormData(boundary: boundary)
        form.appendField(name: "model",    value: "whisper-1")
        form.appendField(name: "language", value: "ja")
        
        // 直前の文字起こし結果をプロンプトとして追加
        if let prompt = previousTranscript {
            form.appendField(name: "prompt", value: prompt)
        }
        try form.appendFile(url: url, fieldName: "file", filename: url.lastPathComponent)
        let formData = try form.encode()

        // ── バックグラウンドセッションを取得 ─────────────────────
        let session = BackgroundSessionManager.shared.backgroundSession

        // ── リクエストを作成 ────────────────────────────────────
        let apiKey = try fetchAPIKey()
        var req = URLRequest(
            url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        )
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(form.contentTypeHeader,  forHTTPHeaderField: "Content-Type")

        // ── リクエストボディを一時ファイルに書き出す ───────────
        let tempDir = FileManager.default.temporaryDirectory
        let tempFormURL = tempDir.appendingPathComponent("upload_\(UUID().uuidString).formdata")
        try formData.write(to: tempFormURL)
        Debug.log("🔵 Wrote form data to temporary file: \(tempFormURL.path)")

        // ── アップロードタスクを作成して開始 ───────────────────
        let task = session.uploadTask(with: req, fromFile: tempFormURL)

        // ── BackgroundSessionManager にタスク情報を登録 ─────────────────────
        BackgroundSessionManager.shared.registerBackgroundTask(
            taskId: task.taskIdentifier, 
            url: url, 
            startTime: started, 
            tempURL: tempFormURL
        )

        Debug.log("🔵 [\(task.taskIdentifier)] Starting background upload task for \(url.lastPathComponent)")
        task.resume()
    }

    /// Keychain Helper などに置き換えてください
    private func fetchAPIKey() throws -> String {
        guard let key = KeychainHelper.shared.apiKey(), !key.isEmpty else {
            throw NSError(domain: "OpenAIClient", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "API キー未設定"])
        }
        return key
    }
}

// MARK: -- Simple Multipart Form-Data builder -------------------------------
/// 極小サイズの multipart/form-data ヘルパ (変更なし)
private struct MultipartFormData {
    struct Part { let header: String; let body: Data }
    private var parts: [Part] = []
    private let boundary: String

    init(boundary: String) { self.boundary = boundary }

    mutating func appendField(name: String, value: String) {
        let header = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        parts.append(.init(header: header, body: value.data(using: .utf8)!))
    }

    mutating func appendFile(url: URL, fieldName: String, filename: String) throws {
        let header =
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: \(mimeType(for: url))\r\n\r\n"
        let data = try Data(contentsOf: url)
        parts.append(.init(header: header, body: data))
    }
    
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        default: return "audio/wav"
        }
    }

    func encode() throws -> Data {
        var out = Data()
        for p in parts {
            out.append("--\(boundary)\r\n".data(using: .utf8)!)
            out.append(p.header.data(using: .utf8)!)
            out.append(p.body)
            out.append("\r\n".data(using: .utf8)!)
        }
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }

    var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }
}

// MARK: - Rate Limiting with Exponential Backoff
    
private extension OpenAIClient {
    static func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        let baseDelay: TimeInterval = 1.0
        let maxDelay: TimeInterval = 60.0
        let delay = baseDelay * pow(2.0, Double(attempt))
        return min(delay, maxDelay)
    }
    
    static func shouldRetryWithBackoff(url: URL) -> (shouldRetry: Bool, delay: TimeInterval) {
        let urlKey = url.lastPathComponent
        let attempts = retryAttempts[urlKey, default: 0]
        
        guard attempts < maxRetryAttempts else {
            retryAttempts.removeValue(forKey: urlKey)
            return (false, 0)
        }
        
        retryAttempts[urlKey] = attempts + 1
        let delay = calculateBackoffDelay(attempt: attempts)
        return (true, delay)
    }
    
    static func resetRetryCount(for url: URL) {
        let urlKey = url.lastPathComponent
        retryAttempts.removeValue(forKey: urlKey)
    }
}