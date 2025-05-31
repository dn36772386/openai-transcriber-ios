import Foundation

struct Debug {

    // MARK: - Private Properties for File Logging

    private static let logFileName = "debug_log.txt"
    private static let logFileURL: URL? = {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(logFileName)

        do {
            // --- ログファイルの設定 (アプリ起動時に上書き) ---
            // もしファイルが存在すれば、一度削除して上書きを保証
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            // 空のファイルを作成 (または初回書き込み時に自動作成)
            try "".write(to: url, atomically: true, encoding: .utf8)
            
            // 📝 コンソールにログファイルの場所を出力
            print("📝 Debug log file will be written to: \(url.path)")
            return url
        } catch {
            print("❌ Failed to set up log file at \(url.path): \(error)")
            return nil
        }
    }()

    // ログ書き込み用のシリアルキュー (スレッドセーフにするため)
    private static let logQueue = DispatchQueue(label: "com.your-app-identifier.debugLogQueue", qos: .background)

    // ログのタイムスタンプ用フォーマッタ
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ" // ISO 8601 形式
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Public Properties

    /// Info.plist の DEBUG_LOG が true なら有効
    static let enabled: Bool = {
        _ = logFileURL // logFileURL を初期化してログファイルの準備を確実に行う
        
        if let boolVal = Bundle.main.object(forInfoDictionaryKey: "DEBUG_LOG") as? Bool {
            return boolVal
        }
        if let str = Bundle.main.object(forInfoDictionaryKey: "DEBUG_LOG") as? String {
            return ["1", "true", "yes"].contains(str.lowercased())
        }
        // デフォルトは false ですが、デバッグ中は true に変更しても良いでしょう
        return true // ◀︎◀︎ 必要に応じて true に変更して強制的に有効化
    }()

    // MARK: - Public Methods

    /// 有効時のみコンソールとファイルに出力
    static func log(_ items: Any...) {
        // enabled が false なら何もしない
        guard enabled else { return }

        // ログメッセージを生成
        let timestamp = dateFormatter.string(from: Date())
        let msg = items.map { String(describing: $0) }.joined(separator: " ")
        let logLine = "\(timestamp) 🛠 \(msg)\n" // タイムスタンプと改行を追加

        // 1. コンソールに出力
        print("🛠", msg)

        // 2. ファイルに非同期で追記
        logQueue.async {
            guard let url = logFileURL, let data = logLine.data(using: .utf8) else { return }

            do {
                // FileHandle を使ってファイルに追記する
                let fileHandle = try FileHandle(forWritingTo: url)
                // ファイルの末尾に移動
                fileHandle.seekToEndOfFile()
                // データを書き込む
                fileHandle.write(data)
                // ファイルハンドルを閉じる
                fileHandle.closeFile()
            } catch {
                // ファイル書き込みエラーをコンソールに出力（無限ループを避けるため）
                print("❌ Failed to write to log file: \(error)")
            }
        }
    }
}

// MARK: - WhisperQueue (元のファイルに含まれていた場合)

import Foundation

actor WhisperQueue {
    private let client = OpenAIClient()
    private let maxConcurrentRequests = 3
    private var activeRequests = 0
    private var pendingRequests: [(url: URL, started: Date)] = []

    func enqueue(url: URL, started: Date) async throws {
        Debug.log("WhisperQueue ▶︎ segment started:", started)
        
        // 同時実行数チェック
        if activeRequests >= maxConcurrentRequests {
            Debug.log("WhisperQueue ⏸️ Queuing request (active: \(activeRequests))")
            pendingRequests.append((url: url, started: started))
            return
        }
        
        activeRequests += 1
        defer { 
            activeRequests -= 1
            // 待機中のリクエストを処理
            if !pendingRequests.isEmpty {
                let next = pendingRequests.removeFirst()
                Task { try? await enqueue(url: next.url, started: next.started) }
            }
        }
        
        Debug.log("WhisperQueue ▶️ Processing request (active: \(activeRequests))")
        // OpenAIClient.transcribeInBackground は @MainActor で実行する必要がある
        try await MainActor.run {
            try client.transcribeInBackground(url: url, started: started)
        }
    }
}

let whisperQueue = WhisperQueue() // グローバルで 1 本
