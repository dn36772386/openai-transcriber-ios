import Foundation

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    private let historyKey = "transcriptionHistory_v3" // キーを変更して以前のデータとの衝突を避ける
    private let maxHistoryItems = 10

    @Published var historyItems: [HistoryItem] = []

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private init() {
        loadHistory()
        print("🗄️ HistoryManager initialized. Documents Directory: \(documentsDirectory.path)")
    }

    func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else {
            self.historyItems = []
            print("ℹ️ No history found in UserDefaults for key: \(historyKey)")
            return
        }
        do {
            let decoder = JSONDecoder()
            let items = try decoder.decode([HistoryItem].self, from: data)
            self.historyItems = items.sorted(by: { $0.date > $1.date })
            print("✅ Loaded \(items.count) history items from UserDefaults.")
        } catch {
            print("❌ Error decoding history: \(error)")
            self.historyItems = []
            // UserDefaults.standard.removeObject(forKey: historyKey) // 不正なデータを削除する場合
        }
    }

    private func saveHistoryItemsToUserDefaults() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.historyItems)
            UserDefaults.standard.set(data, forKey: historyKey)
            print("✅ Saved \(historyItems.count) history items to UserDefaults.")
        } catch {
            print("❌ Error encoding history: \(error)")
        }
    }

    func addHistoryItem(lines: [TranscriptLine], fullAudioURL: URL?) {
        // HistoryItemのinit内でファイルコピーとファイル名設定を行う
        let newItem = HistoryItem(
            lines: lines,
            fullAudioURL: fullAudioURL, // これは一時ディレクトリのURLのはず
            documentsDirectory: self.documentsDirectory
        )

        historyItems.insert(newItem, at: 0)
        print("➕ Added new history item: ID \(newItem.id), Date: \(newItem.date)")

        // 古いアイテムを削除 (音声ファイルも含む)
        while historyItems.count > maxHistoryItems {
            let oldItem = historyItems.removeLast()
            print("古い履歴を削除: \(oldItem.id)")
            deleteAssociatedFiles(for: oldItem)
        }
        
        // 一時ファイル（引数で渡された fullAudioURL）を削除
        if let sourceURL = fullAudioURL, sourceURL.isFileURL {
             do {
                 try FileManager.default.removeItem(at: sourceURL)
                 print("🗑️ Removed temporary full session audio: \(sourceURL.lastPathComponent)")
             } catch {
                 print("⚠️ Error removing temporary full session audio \(sourceURL.path): \(error)")
             }
        }
        // 一時ファイル（引数で渡された lines 内の audioURL）を削除
        lines.forEach { line in
            if let segmentURL = line.audioURL, segmentURL.isFileURL {
                do {
                    try FileManager.default.removeItem(at: segmentURL)
                    // print("🗑️ Removed temporary segment audio: \(segmentURL.lastPathComponent)")
                } catch {
                    // print("⚠️ Error removing temporary segment audio \(segmentURL.path): \(error)")
                }
            }
        }

        saveHistoryItemsToUserDefaults()
        objectWillChange.send() // UI更新のため
    }

    private func deleteAssociatedFiles(for item: HistoryItem) {
        // 全体音声ファイルを削除
        if let fileName = item.fullAudioFileName {
            let fileURL = documentsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    print("🗑️ Deleted full audio file from Documents: \(fileName)")
                } catch {
                    print("❌ Error deleting full audio file \(fileName) from Documents: \(error)")
                }
            }
        }
        // セグメント音声ファイルを削除
        item.transcriptLines.forEach { lineData in
            if let segName = lineData.audioSegmentFileName {
                let segURL = documentsDirectory.appendingPathComponent(segName)
                 if FileManager.default.fileExists(atPath: segURL.path) {
                    do {
                        try FileManager.default.removeItem(at: segURL)
                        // print("🗑️ Deleted segment audio file from Documents: \(segName)")
                    } catch {
                        // print("❌ Error deleting segment audio file \(segName) from Documents: \(error)")
                    }
                 }
            }
        }
    }

    func deleteHistoryItem(at offsets: IndexSet) {
        var itemsToDelete: [HistoryItem] = []
        offsets.forEach { index in
            itemsToDelete.append(historyItems[index])
        }
        for item in itemsToDelete { // 削除対象のファイルも先に消す
             deleteAssociatedFiles(for: item)
        }
        historyItems.remove(atOffsets: offsets)
        saveHistoryItemsToUserDefaults()
        print("🗑️ Deleted history item(s) at offsets: \(offsets)")
    }

    func clearAllHistory() {
        for item in historyItems {
            deleteAssociatedFiles(for: item)
        }
        historyItems.removeAll()
        saveHistoryItemsToUserDefaults()
        print("🗑️ Cleared all history items and associated files.")
    }
}