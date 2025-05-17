import Foundation
import Security
import SwiftUI

enum OpenAIError: Error { case noKey, invalidResponse }

struct OpenAIClient {

    static func transcribe(url: URL) async throws -> String {
        let endpoint = URL(string: "https://api.openai.com/v1")!
        let session = URLSession.shared
        let decoder = JSONDecoder()

        var request = URLRequest(url: endpoint.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(KeychainHelper.shared.apiKey() ?? "")", forHTTPHeaderField: "Authorization")

        var body = Data()

        // model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // file
        let filename = url.lastPathComponent
        let audioData = try Data(contentsOf: url)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // 送信 & デコード
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw OpenAIError.invalidResponse // OpenAIError.server("(http.statusCode): \(msg)")
        }
        // Whisper APIのレスポンス例: { "text": "..." }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw OpenAIError.invalidResponse
        }
        return text
    }
}
