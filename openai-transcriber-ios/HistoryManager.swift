import Foundation

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    private let historyKey = "transcriptionHistory_v3"
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
        // 空のセッションは保存しない
        guard !lines.isEmpty else {
            print("ℹ️ No transcript lines to save")
            return
        }
        
        let newItem = HistoryItem(
            lines: lines,
            fullAudioURL: fullAudioURL,
            documentsDirectory: self.documentsDirectory
        )

        historyItems.insert(newItem, at: 0)
        print("➕ Added new history item: ID \(newItem.id), Date: \(newItem.date)")

        while historyItems.count > maxHistoryItems {
            let oldItem = historyItems.removeLast()
            print("🗑️ Deleting old history item: \(oldItem.id)")
            deleteAssociatedFiles(for: oldItem)
        }
        
        // 一時ファイルの削除は行わない（現在のセッション中は保持する必要があるため）
        // cleanupTemporaryFiles メソッドを別途呼び出すこと

        saveHistoryItemsToUserDefaults()
        objectWillChange.send()
    }

    // 一時ファイルをクリーンアップする専用メソッド
    func cleanupTemporaryFiles(for lines: [TranscriptLine]) {
        lines.forEach { line in
            if let segmentURL = line.audioURL, 
               segmentURL.isFileURL,
               segmentURL.path.contains("/tmp/") { // 一時ディレクトリのファイルのみ削除
                do {
                    try FileManager.default.removeItem(at: segmentURL)
                    print("🗑️ Cleaned up temporary segment audio: \(segmentURL.lastPathComponent)")
                } catch {
                    print("⚠️ Error cleaning up temporary segment audio \(segmentURL.path): \(error)")
                }
            }
        }
    }

    private func deleteAssociatedFiles(for item: HistoryItem) {
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
        item.transcriptLines.forEach { lineData in
            if let segName = lineData.audioSegmentFileName {
                let segURL = documentsDirectory.appendingPathComponent(segName)
                if FileManager.default.fileExists(atPath: segURL.path) {
                    do {
                        try FileManager.default.removeItem(at: segURL)
                    } catch {
                        // エラーログは冗長なので省略
                    }
                }
            }
        }
    }

    func deleteHistoryItem(at offsets: IndexSet) {
        var itemsToDelete: [HistoryItem] = []
        offsets.forEach { index in
            if historyItems.indices.contains(index) {
                itemsToDelete.append(historyItems[index])
            }
        }
        for item in itemsToDelete {
            deleteAssociatedFiles(for: item)
        }
        historyItems.remove(atOffsets: offsets)
        saveHistoryItemsToUserDefaults()
        print("🗑️ Deleted history item(s) at offsets: \(offsets)")
    }

    func deleteHistoryItem(id: UUID) {
        if let index = historyItems.firstIndex(where: { $0.id == id }) {
            let itemToDelete = historyItems.remove(at: index)
            deleteAssociatedFiles(for: itemToDelete)
            saveHistoryItemsToUserDefaults()
            print("🗑️ Deleted history item with ID: \(id)")
        }
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