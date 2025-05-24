import Foundation
import UIKit

// バックグラウンドアップロードを管理するシングルトンクラス
class BackgroundSessionManager: NSObject {
    static let shared = BackgroundSessionManager()
    static let backgroundSessionIdentifier = "com.yourapp.openai-transcriber.backgroundUpload"
    
    private var backgroundCompletionHandler: (() -> Void)?
    
    // 各タスクIDに対応するレスポンスデータを保持
    private var responseDataStore = [Int: Data]()
    // 各タスクIDに対応するメタデータ（元のファイルURL、開始時刻、一時ファイルURL）を保持
    private var taskMetadataStore = [Int: (originalURL: URL, startTime: Date, tempFileURL: URL)]()
    
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
    func registerBackgroundTask(taskId: Int, url: URL, startTime: Date, tempURL: URL) {
        print("🔵 [\(taskId)] Registering task metadata.")
        self.taskMetadataStore[taskId] = (url, startTime, tempURL)
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
        
        var resultText: String?
        var taskError: Error? = error
        
        if let error = error {
            print("❌ [\(taskId)] URLSession Error: \(error.localizedDescription)")
            taskError = error
        } else if let httpResponse = httpResponse, !(200..<300).contains(httpResponse.statusCode) {
            let errorMsg = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown HTTP Error"
            print("❌ [\(taskId)] HTTP Error: \(httpResponse.statusCode) - \(errorMsg)")
            taskError = NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        } else if let data = data {
            do {
                let whisperResp = try JSONDecoder().decode(WhisperResp.self, from: data)
                resultText = whisperResp.text
                print("✅ [\(taskId)] Success: \(resultText ?? "")")
            } catch let decodeError {
                print("❌ [\(taskId)] JSON Decode Error: \(decodeError)")
                taskError = decodeError
            }
        } else {
            print("❌ [\(taskId)] Unknown Error: No error, but no data received.")
            taskError = NSError(domain: "AppError", code: -1, userInfo: [NSLocalizedDescriptionKey: "データが受信できませんでした。"])
        }
        
        // 通知センターを使ってメインアプリに結果を通知
        NotificationCenter.default.post(
            name: .transcriptionDidFinish,
            object: metadata.originalURL,
            userInfo: [
                "text": resultText as Any,
                "error": taskError as Any,
                "startTime": metadata.startTime
            ]
        )
        
        // 完了したタスクのデータをクリーンアップ
        self.cleanupTask(taskId)
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

// WhisperResponse構造体
struct WhisperResp: Decodable {
    let text: String
}