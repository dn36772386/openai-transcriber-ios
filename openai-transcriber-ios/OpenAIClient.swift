import Foundation

enum OpenAIError: Error { case noKey, invalidResponse }

struct OpenAIClient {

    static func transcribe(url: URL) async throws -> String {
        // API キー取得
        guard let apiKey = KeychainHelper.shared.apiKey(), !apiKey.isEmpty
        else { throw OpenAIError.noKey }

        // multipart/form-data
        let boundary = UUID().uuidString
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }

        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        add("whisper-1\r\n")

        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        add("ja\r\n")

        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        add("Content-Type: audio/m4a\r\n\r\n")
        body.append(try Data(contentsOf: url))
        add("\r\n--\(boundary)--\r\n")

        req.httpBody = body

        Debug.log("[OpenAI] POST /v1/audio/transcriptions")
        let (data, response) = try await URLSession.shared.data(for: req)

        if let res = response as? HTTPURLResponse {
            Debug.log("[OpenAI] status =", res.statusCode)
        }

        guard
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else { throw OpenAIError.invalidResponse }

        Debug.log("[OpenAI] transcription length =", text.count)
        return text
    }
}
