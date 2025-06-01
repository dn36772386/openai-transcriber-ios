import Foundation
import UIKit
import UserNotifications

// APIタイプを定義
enum APIType {
    case openai
    case deepgram
}

// バックグラウンドアップロードを管理するシングルトンクラス
class BackgroundSessionManager: NSObject {
    static let shared = BackgroundSessionManager()
    static let backgroundSessionIdentifier = "com.yourapp.openai-transcriber.backgroundUpload"
    
    private var backgroundCompletionHandler: (() -> Void)?
    
    // 各タスクIDに対応するレスポンスデータを保持
    private var responseDataStore = [Int: Data]()
    // 各タスクIDに対応するメタデータ（元のファイルURL、開始時刻、一時ファイルURL、APIタイプ）を保持
    private var taskMetadataStore = [Int: (originalURL: URL, startTime: Date, tempFileURL: URL, apiType: APIType)]()
    
    // リトライ回数を管理
    private var retryCountStore = [Int: Int]()
    // バックグラウンドURLSession
    lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: BackgroundSessionManager.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        super.init()
        print("✅ BackgroundSessionManager initialized")
    }
    
    // バックグラウンドセッションのイベント完了ハンドラを設定
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        self.backgroundCompletionHandler = handler
    }
    
    // タスク情報を登録
    func registerBackgroundTask(taskId: Int, url: URL, startTime: Date, tempURL: URL, apiType: APIType = .openai) {
        print("🔵 [\(taskId)] Registering task metadata.")
        self.taskMetadataStore[taskId] = (url, startTime, tempURL, apiType)
    }
    
    // 内部処理: タスクIDに対応するストアと一時ファイルを削除
    private func cleanupTask(_ taskId: Int) {
        if let metadata = self.taskMetadataStore[taskId] {
            print("🗑️ [\(taskId)] Deleting temp file: \(metadata.tempFileURL.path)")
            try? FileManager.default.removeItem(at: metadata.tempFileURL)
        }
        self.responseDataStore.removeValue(forKey: taskId)
        self.taskMetadataStore.removeValue(forKey: taskId)
    }
}

// MARK: - URLSessionDelegate
extension BackgroundSessionManager: URLSessionDelegate, URLSessionDataDelegate {
    
    // データ受信時に呼ばれる
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskId = dataTask.taskIdentifier
        print("🔵 [\(taskId)] Received data chunk: \(data.count) bytes")
        self.responseDataStore[taskId, default: Data()].append(data)
    }
    
    // タスク完了時に呼ばれる
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        print("🔵 [\(taskId)] Task Completed.")
        
        guard let metadata = self.taskMetadataStore[taskId] else {
            print("❌ [\(taskId)] Metadata not found. Ignoring task completion.")
            self.cleanupTask(taskId)
            return
        }
        let data = self.responseDataStore[taskId]
        let httpResponse = task.response as? HTTPURLResponse
        
        // APIタイプに応じてレスポンスを解析
        let apiType = metadata.apiType
        var resultText: String?
        var taskError: Error? = error
        
        if let error = error {
            print("❌ [\(taskId)] URLSession Error: \(error.localizedDescription)")
            taskError = error
        } else if let httpResponse = httpResponse, !(200..<300).contains(httpResponse.statusCode) {
            let errorMsg = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown HTTP Error"
            print("❌ [\(taskId)] HTTP Error: \(httpResponse.statusCode) - \(errorMsg)")
            
            // 500エラーの場合はリトライ
            if httpResponse.statusCode == 500 {
                let retryCount = retryCountStore[taskId] ?? 0
                if retryCount < 3 {
                    print("🔄 [\(taskId)] Retrying (attempt \(retryCount + 1)/3)...")
                    retryCountStore[taskId] = retryCount + 1
                    
                    // 3秒後にリトライ
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        let tempFileURL = metadata.tempFileURL
                        if FileManager.default.fileExists(atPath: tempFileURL.path) {
                            let retryTask = self.backgroundSession.uploadTask(with: task.originalRequest!, fromFile: tempFileURL)
                            self.taskMetadataStore[retryTask.taskIdentifier] = metadata
                            retryTask.resume()
                        }
                    }
                    return
                }
            }
            
            taskError = NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        } else if let data = data, !data.isEmpty {
            do {
                switch apiType {
                case .openai:
                    let response = try JSONDecoder().decode(WhisperResp.self, from: data)
                    resultText = response.text
                case .deepgram:
                    // 生のJSONレスポンスを確認
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("🔍 Raw Deepgram JSON Response:")
                        // 最初の2000文字を出力
                        let preview = String(jsonString.prefix(2000))
                        print(preview)
                        print("... (total \(jsonString.count) characters)")
                    }
                    
                    let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
                    
                    // デバッグログ
                print("📊 Deepgram Response Debug:")
                print("  - Utterances count: \(response.results.utterances?.count ?? 0)")
                print("  - Channels count: \(response.results.channels.count)")
                if let firstChannel = response.results.channels.first,
                   let firstAlt = firstChannel.alternatives.first {
                    print("  - First transcript: \(firstAlt.transcript)")
                    print("  - Confidence: \(firstAlt.confidence)")
                }
                
                if let utterances = response.results.utterances {
                    print("  - Speakers: \(Set(utterances.compactMap { $0.speaker }).map { $0 + 1 })")
                }
                    
                    // 話者分離された発話を統合
                    if let utterances = response.results.utterances, !utterances.isEmpty {
                        // すべてのutterancesを連結
                        resultText = utterances.map { $0.transcript }.joined(separator: " ")
                        print("✅ [Deepgram] Using utterances: \(utterances.count) items")
                    } else {
                        // フォールバック: 通常の文字起こし結果
                        if let transcript = response.results.channels.first?.alternatives.first?.transcript {
                            resultText = transcript
                            print("✅ [Deepgram] Using channel transcript: \(transcript)")
                        } else {
                            resultText = ""
                            print("❌ [Deepgram] No transcript found in response")
                        }
                    }
                }
                print("✅ [\(taskId)] API Response parsed successfully")
            } catch let decodeError {
                print("❌ [\(taskId)] JSON Decode Error: \(decodeError)")
                taskError = decodeError
            }
        } else {
            print("❌ [\(taskId)] Unknown Error: No error, but no data received.")
            taskError = NSError(domain: "AppError", code: -1, userInfo: [NSLocalizedDescriptionKey: "データが受信できませんでした。"])
        }
        
        // Deepgramの場合、utterancesを含める
        var userInfo: [String: Any] = [
            "text": resultText as Any,
            "error": taskError as Any,
            "startTime": metadata.startTime,
            "apiType": metadata.apiType as Any
        ]
        
        if metadata.apiType == .deepgram, let data = data {
            if let response = try? JSONDecoder().decode(DeepgramResponse.self, from: data),
               let utterances = response.results.utterances {
                userInfo["utterances"] = utterances
            }
        }
         
         // 通知センターを使ってメインアプリに結果を通知
         NotificationCenter.default.post(
             name: .transcriptionDidFinish,
             object: metadata.originalURL,
             userInfo: userInfo
         )
 
        // 個別のセグメント通知は送信しない
        // ContentViewの showCompletionNotification() で
        // 全体の完了通知のみを送信する
        
        // // Send background notification if needed
        // if UIApplication.shared.applicationState != .active {
        //     sendBackgroundNotification(success: taskError == nil, taskId: taskId)
        // }

        // 完了したタスクのデータをクリーンアップ
        self.cleanupTask(taskId)
        self.retryCountStore.removeValue(forKey: taskId)
    }
    
    // 全てのイベントが処理された後に呼ばれる
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("🔵 URLSessionDidFinishEvents - Calling backgroundCompletionHandler.")
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

// OpenAIWhisperResponse構造体
struct OpenAIWhisperResponse: Decodable {
    let text: String
}

// WhisperResp構造体（後方互換性のため）
typealias WhisperResp = OpenAIWhisperResponse

// MARK: - Notification Methods

extension BackgroundSessionManager {
    
    private func sendBackgroundNotification(success: Bool, taskId: Int) {
        let content = UNMutableNotificationContent()
        content.title = success ? "文字起こし成功" : "文字起こしエラー"
        content.body = success ? "音声セグメントの文字起こしが完了しました" : "音声セグメントの文字起こしに失敗しました"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "transcription-\(taskId)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Failed to send background notification: \(error)")
            }
        }
    }
}