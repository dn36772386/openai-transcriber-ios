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

        // ── multipart/form-data を構築 ──────────────────────────────
        var form = MultipartFormData()
        form.append(url, name: "file", filename: url.lastPathComponent)
        form.append("whisper-1", name: "model")
        form.append("ja",        name: "language")            // ★日本語固定

        if !recentContext.isEmpty {                           // ★前文をヒントに
            form.append(String(recentContext.suffix(maxPromptLen)),
                        name: "prompt")
        }

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

        // 次回 prompt 用に文字列を蓄積 (無限増を避けるリングバッファ方式でも OK)
        recentContext.append(result)

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

    private var parts: [Part] = []
    private let boundary = "----OpenAI-Transcriber-\(UUID().uuidString)"

    mutating func append(
        _ string: String, name: String
    ) {
        parts.append(.init(
            header:
                """
                Content-Disposition: form-data; name="\(name)"

                """,
            body: Data(string.utf8)
        ))
    }

    mutating func append(
        _ fileURL: URL, name: String, filename: String
    ) {
        // ファイル読み込み失敗は上位に投げる
        let data = try! Data(contentsOf: fileURL)
        let mime = mimeType(for: fileURL.pathExtension)

        parts.append(.init(
            header:
                """
                Content-Disposition: form-data; name="\(name)"; filename="\(filename)"
                Content-Type: \(mime)

                """,
            body: data
        ))
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
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }

    var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    private struct Part {
        let header: String
        let body: Data
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "wav":  return "audio/wav"
        case "webm": return "audio/webm"
        case "m4a":  return "audio/m4a"
        default:     return "application/octet-stream"
        }
    }
}
