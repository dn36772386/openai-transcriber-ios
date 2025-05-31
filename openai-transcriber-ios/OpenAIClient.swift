import Foundation
import UIKit

/// OpenAI 音声文字起こしクライアント
///
/// * Keychain から API キーを取得 → Bearer 認証
/// * multipart/form-data で音声ファイルをアップロード
/// * 1 クラス = 1 エンドポイントのシンプル実装
final class OpenAIClient {

    // MARK: - Public API
    /// バックグラウンドセッションを使ってアップロードを開始 (戻り値なし)
    /// - Parameters:
    ///   - url: 音声ファイルのURL
    ///   - started: セグメントの開始時刻
    @MainActor
    func transcribeInBackground(url: URL, started: Date) throws {
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
        // prompt は省略
        try form.appendFile(url: url, fieldName: "file", filename: "audio.wav")
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
            "Content-Type: audio/wav\r\n\r\n"
        let data = try Data(contentsOf: url)
        parts.append(.init(header: header, body: data))
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