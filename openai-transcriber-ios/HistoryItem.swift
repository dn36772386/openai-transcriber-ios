import Foundation

// MARK: - TranscriptLine
// TranscriptViewなど他の場所でも使われるため、グローバルスコープに定義 (または適切な場所に)
struct TranscriptLine: Identifiable, Equatable {
    let id: UUID // 初期化時に渡される想定
    var time: Date
    var text: String
    var audioURL: URL?

    static func == (lhs: TranscriptLine, rhs: TranscriptLine) -> Bool {
        lhs.id == rhs.id && lhs.time == rhs.time && lhs.text == rhs.text && lhs.audioURL == rhs.audioURL
    }
    
    // TranscriptLineDataへの変換メソッド (HistoryManager.addHistoryItemで直接行うので必須ではない)
    func toTranscriptLineData(documentsDirectory: URL, historyItemId: UUID) -> HistoryItem.TranscriptLineData {
        var segmentFileName: String? = nil
        if let sourceURL = self.audioURL {
            let fileName = "segment_\(historyItemId.uuidString)_\(self.id.uuidString).wav"
            let destinationURL = documentsDirectory.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                segmentFileName = fileName
            } catch {
                print("❌ Error copying segment audio \(sourceURL.path) to \(destinationURL.path): \(error)")
            }
        }
        return HistoryItem.TranscriptLineData(id: self.id, time: self.time, text: self.text, audioSegmentFileName: segmentFileName)
    }
}

// MARK: - History Item
struct HistoryItem: Identifiable, Codable {
    let id: UUID
    var date: Date
    var transcriptLines: [TranscriptLineData] // 文字起こし結果 (Codable用)
    var fullAudioFileName: String?            // セッション全体の音声ファイル名 (Documents内)

    // Codable対応のためのシンプルな文字起こしデータ構造
    struct TranscriptLineData: Identifiable, Codable {
        let id: UUID
        var time: Date
        var text: String
        var audioSegmentFileName: String? // 個別セグメントのファイル名 (Documents内)
    }

    init(id: UUID = UUID(), date: Date = Date(), lines: [TranscriptLine], fullAudioURL: URL?, documentsDirectory: URL) {
        self.id = id
        self.date = date
        self.fullAudioFileName = nil // まずnilで初期化

        // 1. セッション全体の音声ファイルをDocumentsにコピーし、ファイル名を保存
        if let sourceFullAudioURL = fullAudioURL {
            // historyItemのIDを使ってユニークなファイル名を生成
            let uniqueFullAudioFileName = "full_session_\(self.id.uuidString).\(sourceFullAudioURL.pathExtension)"
            let destinationFullAudioURL = documentsDirectory.appendingPathComponent(uniqueFullAudioFileName)
            do {
                try FileManager.default.copyItem(at: sourceFullAudioURL, to: destinationFullAudioURL)
                self.fullAudioFileName = uniqueFullAudioFileName
                print("✅ Saved full audio to: \(destinationFullAudioURL.path)")
            } catch {
                print("❌ Error copying full audio from \(sourceFullAudioURL.path) to \(destinationFullAudioURL.path): \(error)")
            }
        }
        
        // 2. TranscriptLine を TranscriptLineData に変換し、セグメント音声もコピー
        self.transcriptLines = lines.map { line in
            var segmentFileNameForData: String? = nil
            if let sourceSegmentURL = line.audioURL {
                // historyItemのIDとlineのIDを使ってユニークなファイル名を生成
                let uniqueSegmentFileName = "segment_\(self.id.uuidString)_\(line.id.uuidString).\(sourceSegmentURL.pathExtension)"
                let destinationSegmentURL = documentsDirectory.appendingPathComponent(uniqueSegmentFileName)
                do {
                    try FileManager.default.copyItem(at: sourceSegmentURL, to: destinationSegmentURL)
                    segmentFileNameForData = uniqueSegmentFileName
                } catch {
                    print("❌ Error copying segment audio from \(sourceSegmentURL.path) to \(destinationSegmentURL.path): \(error)")
                }
            }
            return TranscriptLineData(id: line.id, time: line.time, text: line.text, audioSegmentFileName: segmentFileNameForData)
        }
    }

    // 履歴読み込み時に TranscriptLineData配列をTranscriptLine配列に変換する
    func getTranscriptLines(documentsDirectory: URL) -> [TranscriptLine] {
        return self.transcriptLines.map { data in
            var url: URL? = nil
            if let fileName = data.audioSegmentFileName {
                let potentialURL = documentsDirectory.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: potentialURL.path) {
                    url = potentialURL
                } else {
                    print("⚠️ Segment file not found: \(fileName)")
                }
            }
            return TranscriptLine(id: data.id, time: data.time, text: data.text, audioURL: url)
        }
    }
    
    // 履歴読み込み時に全体音声のURLを取得する
    func getFullAudioURL(documentsDirectory: URL) -> URL? {
        guard let fileName = self.fullAudioFileName else { return nil }
        let url = documentsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}