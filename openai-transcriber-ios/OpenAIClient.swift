//
//  OpenAIClient.swift
//  openai-transcriber-ios
//
//  Whisper (audio ↦ text) 専用の極小クライアント。
//  — 2025-05-xx 版
//

import Foundation

/// Whisper API のレスポンス（必要最小限）
private struct WhisperResp: Decodable {
    let text: String
}

/// OpenAI 音声文字起こしクライアント
///
/// * language は常に **ja**
/// * 直前までの結果を prompt に 120 文字以内で添付
/// * 1 クラス = 1 エンドポイントのシンプル実装
final class OpenAIClient {

    // MARK: - Public API
    /// 録音した WAV / WEBM などの一時ファイルを送って文字列を取得
    @MainActor
    func transcribe(url: URL) async throws -> String {
        // ── 0 byte／極小ファイルは送信しない ─────────────────────
        let attr  = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attr[.size] as? NSNumber)?.intValue ?? 0
        guard bytes >= 4_096 else {                            // 4 kB 未満は破棄
            throw NSError(domain: "Whisper", code: -3,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Audio too short (\(bytes) bytes) – skipped"])
        }

        // ── multipart/form-data を構築 ──────────────────────────────
        let boundary = "Boundary-\(UUID().uuidString)"      // 送信ごとに一意
        var form = MultipartFormData(boundary: boundary)

        // 必須フィールド
        form.appendField(name: "model",    value: "whisper-1")
        form.appendField(name: "language", value: "ja")

        // 直前の文字列を 120 文字以内で prompt にセット（任意）
        if !recentContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let prompt = String(recentContext.suffix(maxPromptLen))
            form.appendField(name: "prompt", value: prompt)
        }

        // 録音ファイル
        try form.appendFile(url: url, fieldName: "file", filename: "audio.wav")

        // ── 送信 ────────────────────────────────────────────────
        let (data, resp) = try await send(form)

        // ── デバッグログ（HTTP 応答と本文）──────────────────
        if let http = resp as? HTTPURLResponse {
            Debug.log("🔵 Whisper status =", http.statusCode)
            Debug.log(String(decoding: data, as: UTF8.self))
        }

        // ステータスコードではじく (>=400 はエラー扱い)
        guard let http = resp as? HTTPURLResponse,
              200 ..< 300 ~= http.statusCode else {
            let msg = String(data: data, encoding: .utf8) ??
                      "status=\((resp as? HTTPURLResponse)?.statusCode ?? -1)"
            throw NSError(domain: "Whisper", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // ── JSON Decode ─────────────────────────────────────────
        let result = try JSONDecoder().decode(WhisperResp.self, from: data).text

        // 次回 prompt 用に文字列を蓄積（長さ上限 1 000 字で切り捨て）
        recentContext.append(result)
        if recentContext.count > 1_000 {
            recentContext.removeFirst(recentContext.count - 1_000)
        }

        return result
    }

    // MARK: - Internal helpers
    /// `Content-Type: multipart/form-data` で送信して (Data, URLResponse) を返す
    private func send(_ form: MultipartFormData) async throws -> (Data, URLResponse) {

        let apiKey = try fetchAPIKey()          // Keychain などから取得（下記参照）

        var req = URLRequest(
            url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        )
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(form.contentTypeHeader,  forHTTPHeaderField: "Content-Type")
        req.httpBody = try form.encode()

        return try await URLSession.shared.data(for: req)
    }

    /// Keychain Helper などに置き換えてください
    private func fetchAPIKey() throws -> String {
        guard let key = KeychainHelper.shared.apiKey(), !key.isEmpty else {
            throw NSError(domain: "OpenAIClient", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "API キー未設定"])
        }
        return key
    }

    // MARK: - Private state
    private var recentContext = ""                   // 直近の全文
    private let maxPromptLen  = 120                  // Whisper 推奨は ≤224 chars
}

// MARK: -- Simple Multipart Form-Data builder -------------------------------

/// 極小サイズの multipart/form-data ヘルパ
private struct MultipartFormData {
    struct Part { let header: String; let body: Data }
    private var parts: [Part] = []
    private let boundary: String

    init(boundary: String) { self.boundary = boundary }

    /// 文字列フィールドを追加
    mutating func appendField(name: String, value: String) {
        let header =
            "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        parts.append(.init(header: header, body: value.data(using: .utf8)!))
    }

    /// 録音ファイルをパートに追加
    mutating func appendFile(url: URL, fieldName: String, filename: String) throws {
        let header =
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n" +
            "Content-Type: audio/wav\r\n\r\n"
        let data = try Data(contentsOf: url)
        parts.append(.init(header: header, body: data))
    }

    /// 最終的な HTTP Body
    func encode() throws -> Data {
        var out = Data()
        for p in parts {
            out.append("--\(boundary)\r\n".data(using: .utf8)!)
            out.append(p.header.data(using: .utf8)!)
            out.append(p.body)
            out.append("\r\n".data(using: .utf8)!)
        }
        // ── multipart 終端 ──
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }

    var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }
}
