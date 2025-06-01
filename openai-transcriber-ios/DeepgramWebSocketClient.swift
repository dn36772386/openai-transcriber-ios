import Foundation
import AVFoundation

// MARK: - Deepgram WebSocket Client
@MainActor
final class DeepgramWebSocketClient: NSObject, ObservableObject {
    
    // MARK: - Properties
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var transcriptLines: [TranscriptLine] = []
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var keepAliveTimer: Timer?
    private let keepAliveInterval: TimeInterval = 8.0
    
    // コールバック
    var onTranscript: ((TranscriptLine) -> Void)?
    var onError: ((Error) -> Void)?
    
    // 話者ごとの進行中のテキストを保持
    private var speakerBuffers: [Int: (text: String, startTime: Double)] = [:]
    private var baseStartTime = Date()
    
    // MARK: - Initialization
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    // MARK: - Connection Management
    func connect() async throws {
        guard !isConnected && !isConnecting else { return }
        
        isConnecting = true
        
        // APIキー取得
        guard let apiKey = KeychainHelper.shared.deepgramApiKey(), !apiKey.isEmpty else {
            isConnecting = false
            throw NSError(domain: "DeepgramWebSocket", code: 0, userInfo: [NSLocalizedDescriptionKey: "Deepgram APIキーが設定されていません"])
        }
        
        // WebSocket URL構築
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "language", value: "ja"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1")
        ]
        
        guard let url = components.url else {
            isConnecting = false
            throw NSError(domain: "DeepgramWebSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "無効なURL"])
        }
        
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // WebSocketタスク作成
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        
        // メッセージ受信開始
        receiveMessage()
        
        // Keep-Aliveタイマー開始
        startKeepAliveTimer()
        
        isConnecting = false
        isConnected = true
        baseStartTime = Date()
        
        print("🔌 Deepgram WebSocket connected")
    }
    
    func disconnect() {
        guard isConnected else { return }
        
        // CloseStreamメッセージを送信
        let closeMessage = ["type": "CloseStream"]
        if let jsonData = try? JSONSerialization.data(withJSONObject: closeMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { _ in }
        }
        
        // 接続をクローズ
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        stopKeepAliveTimer()
        isConnected = false
        speakerBuffers.removeAll()
        
        print("🔌 Deepgram WebSocket disconnected")
    }
    
    // MARK: - Audio Streaming
    func sendAudioData(_ audioData: Data) {
        guard isConnected else { return }
        
        let message = URLSessionWebSocketTask.Message.data(audioData)
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                print("❌ Failed to send audio data: \(error)")
                Task { @MainActor in
                    self?.onError?(error)
                }
            }
        }
    }
    
    // MARK: - Message Handling
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                self.handleMessage(message)
                // 次のメッセージを受信
                self.receiveMessage()
                
            case .failure(let error):
                print("❌ WebSocket receive error: \(error)")
                Task { @MainActor in
                    self.onError?(error)
                    self.isConnected = false
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            // バイナリメッセージは通常来ない
            print("📦 Received binary message: \(data.count) bytes")
        @unknown default:
            break
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to parse JSON: \(text)")
            return
        }
        
        // メッセージタイプの確認
        if let type = json["type"] as? String {
            switch type {
            case "Results":
                handleTranscriptionResult(json)
            case "Metadata":
                print("📊 Metadata: \(json)")
            case "Error":
                handleError(json)
            default:
                print("🔍 Unknown message type: \(type)")
            }
        }
    }
    
    private func handleTranscriptionResult(_ json: [String: Any]) {
        guard let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let transcript = firstAlt["transcript"] as? String,
              let words = firstAlt["words"] as? [[String: Any]] else {
            return
        }
        
        let isFinal = json["is_final"] as? Bool ?? false
        let speechFinal = json["speech_final"] as? Bool ?? false
        
        // 空のトランスクリプトは無視
        guard !transcript.isEmpty else { return }
        
        // 話者ごとにテキストを分割
        var currentSpeaker: Int? = nil
        var currentText: [String] = []
        var segments: [(speaker: Int, text: String, start: Double, end: Double)] = []
        
        for word in words {
            guard let wordText = word["word"] as? String,
                  let start = word["start"] as? Double,
                  let end = word["end"] as? Double else { continue }
            
            let speaker = word["speaker"] as? Int ?? 0
            
            if currentSpeaker != nil && currentSpeaker != speaker {
                // 話者が変わった
                if !currentText.isEmpty {
                    let text = currentText.joined(separator: " ")
                    if let firstWord = words.first(where: { ($0["speaker"] as? Int ?? 0) == currentSpeaker }),
                       let lastWord = words.last(where: { ($0["speaker"] as? Int ?? 0) == currentSpeaker }),
                       let startTime = firstWord["start"] as? Double,
                       let endTime = lastWord["end"] as? Double {
                        segments.append((speaker: currentSpeaker!, text: text, start: startTime, end: endTime))
                    }
                }
                currentText = []
            }
            
            currentSpeaker = speaker
            currentText.append(wordText)
        }
        
        // 最後のセグメントを追加
        if let speaker = currentSpeaker, !currentText.isEmpty {
            let text = currentText.joined(separator: " ")
            if let firstWord = words.first(where: { ($0["speaker"] as? Int ?? 0) == speaker }),
               let lastWord = words.last(where: { ($0["speaker"] as? Int ?? 0) == speaker }),
               let startTime = firstWord["start"] as? Double,
               let endTime = lastWord["end"] as? Double {
                segments.append((speaker: speaker, text: text, start: startTime, end: endTime))
            }
        }
        
        // speechFinalの場合、話者ごとの文字起こしを確定
        if speechFinal {
            Task { @MainActor in
                for segment in segments {
                    let transcriptLine = TranscriptLine(
                        id: UUID(),
                        time: baseStartTime.addingTimeInterval(segment.start),
                        text: segment.text,
                        audioURL: nil,
                        speaker: "話者\(segment.speaker + 1)"
                    )
                    self.transcriptLines.append(transcriptLine)
                    self.onTranscript?(transcriptLine)
                    
                    print("🎙️ [話者\(segment.speaker + 1)] \(segment.text)")
                }
                
                // バッファをクリア
                speakerBuffers.removeAll()
            }
        }
    }
    
    private func handleError(_ json: [String: Any]) {
        let errorMessage = json["message"] as? String ?? "Unknown error"
        print("❌ Deepgram error: \(errorMessage)")
        
        Task { @MainActor in
            let error = NSError(domain: "DeepgramWebSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            self.onError?(error)
        }
    }
    
    // MARK: - Keep Alive
    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            self?.sendKeepAlive()
        }
    }
    
    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
    
    private func sendKeepAlive() {
        let keepAlive = ["type": "KeepAlive"]
        if let jsonData = try? JSONSerialization.data(withJSONObject: keepAlive),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { error in
                if let error = error {
                    print("❌ Failed to send keep-alive: \(error)")
                }
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
extension DeepgramWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WebSocket connection opened")
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("🔴 WebSocket connection closed: \(closeCode)")
        Task { @MainActor in
            self.isConnected = false
        }
    }
}
