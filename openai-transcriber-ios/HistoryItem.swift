import Foundation

// MARK: - TranscriptLine
// TranscriptViewなど他の場所でも使われるため、HistoryItem.swiftの先頭などに一元化
struct TranscriptLine: Identifiable, Equatable {
    let id: UUID // 初期化時に渡される想定
    var time: Date
    var text: String
    var audioURL: URL?
    var speaker: String? // 話者情報を追加

    static func == (lhs: TranscriptLine, rhs: TranscriptLine) -> Bool {
        lhs.id == rhs.id && lhs.time == rhs.time && lhs.text == rhs.text && lhs.audioURL == rhs.audioURL && lhs.speaker == rhs.speaker
    }

    // HistoryItem.TranscriptLineDataへの変換メソッド (オプション)
    func toTranscriptLineData(audioStorageDirectory: URL, historyItemId: UUID) -> HistoryItem.TranscriptLineData {
        var segmentFileName: String? = nil
        if let sourceURL = self.audioURL {
            // 既にDocuments内のファイルの場合はコピーしない
            if sourceURL.path.contains(audioStorageDirectory.path) {
                // 既にDocuments内なのでファイル名だけ取得
                segmentFileName = sourceURL.lastPathComponent
            } else {
                // セグメントごとにユニークなファイル名を生成 (履歴アイテムIDとセグメントIDを使用)
                let fileName = "segment_\(historyItemId.uuidString)_\(self.id.uuidString).\(sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension)"
                let destinationURL = audioStorageDirectory.appendingPathComponent(fileName)
                do {
                    // コピー先に同名ファイルが存在する場合は上書きを試みる (またはエラー処理)
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    segmentFileName = fileName
                } catch {
                    print("❌ Error copying segment audio \(sourceURL.path) to \(destinationURL.path): \(error)")
                }
            }
        }
        return HistoryItem.TranscriptLineData(id: self.id, time: self.time, text: self.text, audioSegmentFileName: segmentFileName, speaker: self.speaker)
    }
}

// MARK: - History Item
struct HistoryItem: Identifiable, Codable {
    let id: UUID
    var date: Date
    var fullAudioFileName: String?            // セッション全体の音声ファイル名 (Documents内)
    var transcriptLines: [TranscriptLineData] // 文字起こし結果 (Codable用)
    var summary: String?                       // 要約テキスト
    var subtitle: String?                      // サブタイトル

    // Codable対応のためのシンプルな文字起こしデータ構造
    struct TranscriptLineData: Identifiable, Codable {
        let id: UUID
        var time: Date
        var text: String
        var audioSegmentFileName: String? // 個別セグメントのファイル名 (Documents内)
        var speaker: String? // 話者情報を追加
    }

    init(id: UUID = UUID(), date: Date = Date(), lines: [TranscriptLine], fullAudioURL: URL?, audioStorageDirectory: URL, summary: String? = nil, subtitle: String? = nil) {
        self.id = id
        self.date = date
        self.summary = summary
        self.subtitle = subtitle

        // 1. セッション全体の音声ファイルをDocumentsにコピーし、ファイル名を保存
        // fullAudioFileName を先に初期化 (self.id を使用するため)
        var tempFullAudioFileName: String? = nil
        if let sourceFullAudioURL = fullAudioURL {
            // 既にDocuments内のファイルの場合はコピーしない
            if sourceFullAudioURL.path.contains(audioStorageDirectory.path) {
                tempFullAudioFileName = sourceFullAudioURL.lastPathComponent
            } else {
                let uniqueFullAudioFileName = "full_session_\(self.id.uuidString).\(sourceFullAudioURL.pathExtension.isEmpty ? "wav" : sourceFullAudioURL.pathExtension)"
                let destinationFullAudioURL = audioStorageDirectory.appendingPathComponent(uniqueFullAudioFileName)
                do {
                    if FileManager.default.fileExists(atPath: destinationFullAudioURL.path) {
                        try FileManager.default.removeItem(at: destinationFullAudioURL)
                    }
                    try FileManager.default.copyItem(at: sourceFullAudioURL, to: destinationFullAudioURL)
                    tempFullAudioFileName = uniqueFullAudioFileName // 一時変数に格納
                    print("✅ Saved full audio to: \(destinationFullAudioURL.path)")
                } catch {
                    print("❌ Error copying full audio from \(sourceFullAudioURL.path) to \(destinationFullAudioURL.path): \(error)")
                }
            }
        }
        self.fullAudioFileName = tempFullAudioFileName // プロパティに代入
        
        // 2. TranscriptLine を TranscriptLineData に変換し、セグメント音声もコピー
        // transcriptLines を初期化 (self.id と documentsDirectory を使用)
        self.transcriptLines = lines.map { line in
            // lineからTranscriptLineDataを生成し、その際に音声ファイルもコピーする
            
            line.toTranscriptLineData(audioStorageDirectory: audioStorageDirectory, historyItemId: id) // self.id を id に変更
        }
    }

    // 履歴読み込み時に TranscriptLineData配列をTranscriptLine配列に変換する
    func getTranscriptLines(audioStorageDirectory: URL) -> [TranscriptLine] {
        return self.transcriptLines.map { data in
            var url: URL? = nil
            if let fileName = data.audioSegmentFileName {
                let potentialURL = audioStorageDirectory.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: potentialURL.path) {
                    url = potentialURL
                } else {
                    print("⚠️ Segment file not found in Documents: \(fileName)")
                }
            }
            // TranscriptLineのイニシャライザがidを要求する場合
            return TranscriptLine(id: data.id, time: data.time, text: data.text, audioURL: url, speaker: data.speaker)
        }
    }
    
    // 履歴読み込み時に全体音声のURLを取得する
    func getFullAudioURL(audioStorageDirectory: URL) -> URL? {
        guard let fileName = self.fullAudioFileName else { return nil }
        let url = audioStorageDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}