import Foundation
import OpenAI

enum OpenAIService {
    private static let client = OpenAI(apiToken: APIKeyProvider.fetch())
    static func transcribe(url: URL) async throws -> String {
        let req = AudioTranscriptionRequest(
            fileURL: url,
            model: .whisper_1,
            language: "ja"
        )
        return try await client.audio.transcriptions(request: req).text
    }
}
