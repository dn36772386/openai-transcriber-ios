import Foundation

struct Debug {
    /// Info.plist の DEBUG_LOG が true なら有効
    static let enabled: Bool = {
        if let boolVal = Bundle.main.object(forInfoDictionaryKey: "DEBUG_LOG") as? Bool {
            return boolVal
        }
        if let str = Bundle.main.object(forInfoDictionaryKey: "DEBUG_LOG") as? String {
            return ["1", "true", "yes"].contains(str.lowercased())
        }
        return false
    }()

    /// 有効時のみ標準出力
    static func log(_ items: Any...) {
        guard enabled else { return }
        let msg = items.map { String(describing: $0) }.joined(separator: " ")
        print("🛠", msg)
    }
}

actor WhisperQueue {
    private let semaphore = DispatchSemaphore(value: 1) // 逐次送信
    func enqueue(url: URL, started: Date) async throws -> String {
        semaphore.wait()
        defer { semaphore.signal() }
        return try await OpenAIClient.transcribe(url: url)
    }
}

let whisperQueue = WhisperQueue() // グローバルで 1 本
