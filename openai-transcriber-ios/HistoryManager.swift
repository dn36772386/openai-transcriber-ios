import Foundation

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    private let historyKey = "transcriptionHistory_v3"
    private let maxHistoryItems = 10

    @Published var historyItems: [HistoryItem] = []
    @Published var currentHistoryId: UUID? = nil

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    // 音声ファイル専用ディレクトリ
    var audioStorageDirectory: URL {
        let audioDir = documentsDirectory.appendingPathComponent("AudioFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        return audioDir
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

    func addHistoryItem(lines: [TranscriptLine], fullAudioURL: URL?, summary: String? = nil, subtitle: String? = nil) {
        guard !lines.isEmpty else {
            print("ℹ️ No transcript lines to save")
            return
        }
        
        let newItem = HistoryItem(
            lines: lines,
            fullAudioURL: fullAudioURL,
            audioStorageDirectory: self.audioStorageDirectory,
            summary: summary,
            subtitle: subtitle
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
    
    func startNewSession() -> UUID {
        let newItem = HistoryItem(
            id: UUID(),
            date: Date(),
            lines: [],
            fullAudioURL: nil,
            audioStorageDirectory: self.audioStorageDirectory,
            summary: nil,
            subtitle: nil
        )

        historyItems.insert(newItem, at: 0)
        print("➕ Started new history item: ID \(newItem.id)")

        while historyItems.count > maxHistoryItems {
            let oldItem = historyItems.removeLast()
            print("🗑️ Deleting old history item (due to new session): \(oldItem.id)")
            deleteAssociatedFiles(for: oldItem)
        }

        self.currentHistoryId = newItem.id
        objectWillChange.send()
        saveHistoryItemsToUserDefaults()  // 追加：保存を確実に
        return newItem.id
    }
    
    func updateHistoryItem(id: UUID, lines: [TranscriptLine], fullAudioURL: URL?, summary: String?, subtitle: String?) {
        guard !lines.isEmpty || fullAudioURL != nil || summary != nil else {
            print("⚠️ Update skipped: No data to save for ID \(id)")
            return
        }
        
        guard let index = historyItems.firstIndex(where: { $0.id == id }) else {
            print("⚠️ Update failed: History item with ID \(id) not found. Adding as new.")
            addHistoryItem(lines: lines, fullAudioURL: fullAudioURL, summary: summary, subtitle: subtitle)
            return
        }
        
        let existingItem = historyItems[index]
        
        // 既存の要約とサブタイトルを保持（nilでない場合）
        let finalSummary = summary ?? existingItem.summary
        let finalSubtitle = subtitle ?? existingItem.subtitle
        
        // linesが空の場合は既存のlinesを保持
        let finalLines = lines.isEmpty ? existingItem.getTranscriptLines(audioStorageDirectory: self.audioStorageDirectory) : lines
        
        // fullAudioURLがnilの場合は既存のものを保持
        let finalFullAudioURL = fullAudioURL ?? existingItem.getFullAudioURL(audioStorageDirectory: self.audioStorageDirectory)
        
        deleteAssociatedFiles(for: existingItem)
        
        let updatedItem = HistoryItem(
            id: id,
            date: existingItem.date,
            lines: finalLines,
            fullAudioURL: finalFullAudioURL,
            audioStorageDirectory: self.audioStorageDirectory,
            summary: finalSummary,
            subtitle: finalSubtitle
        )
        
        historyItems[index] = updatedItem
        saveHistoryItemsToUserDefaults()
        objectWillChange.send()
        cleanupOrphanedAudioFiles()  // 孤立したファイルをクリーンアップ
        
        print("📝 Updated history item: ID \(id)")
    }
    
    func saveOrUpdateCurrentSession(currentId: UUID?, lines: [TranscriptLine], fullAudioURL: URL?, summary: String?, subtitle: String?) {
        guard !lines.isEmpty || fullAudioURL != nil || summary != nil else {
            print("ℹ️ No data to save")
            return
        }
        
        if let currentId = currentId {
            updateHistoryItem(id: currentId, lines: lines, fullAudioURL: fullAudioURL, summary: summary, subtitle: subtitle)
        } else {
            addHistoryItem(lines: lines, fullAudioURL: fullAudioURL, summary: summary, subtitle: subtitle)
        }
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
            let fileURL = audioStorageDirectory.appendingPathComponent(fileName)
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
                let segURL = audioStorageDirectory.appendingPathComponent(segName)
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
            // 削除する履歴が現在表示中の場合はリセット
            if currentHistoryId == item.id {
                currentHistoryId = nil
            }
        }
        historyItems.remove(atOffsets: offsets)
        saveHistoryItemsToUserDefaults()
        print("🗑️ Deleted history item(s) at offsets: \(offsets)")
    }

    func deleteHistoryItem(id: UUID) {
        if let index = historyItems.firstIndex(where: { $0.id == id }) {
            let itemToDelete = historyItems.remove(at: index)
            deleteAssociatedFiles(for: itemToDelete)
            if currentHistoryId == id {
                currentHistoryId = nil
            }
            saveHistoryItemsToUserDefaults()
            print("🗑️ Deleted history item with ID: \(id)")
        }
    }

    func clearAllHistory() {
        for item in historyItems {
            deleteAssociatedFiles(for: item)
        }
        historyItems.removeAll()
        currentHistoryId = nil
        saveHistoryItemsToUserDefaults()
        print("🗑️ Cleared all history items and associated files.")
    }
    
    // 孤立した音声ファイルをクリーンアップ
    private func cleanupOrphanedAudioFiles() {
        do {
            let allFiles = try FileManager.default.contentsOfDirectory(at: audioStorageDirectory, includingPropertiesForKeys: nil)
            var validFileNames = Set<String>()
            
            // 履歴に含まれるファイル名を収集
            for item in historyItems {
                if let fullAudio = item.fullAudioFileName {
                    validFileNames.insert(fullAudio)
                }
                for line in item.transcriptLines {
                    if let segmentFile = line.audioSegmentFileName {
                        validFileNames.insert(segmentFile)
                    }
                }
            }
            
            // 履歴に含まれないファイルを削除
            for fileURL in allFiles {
                let fileName = fileURL.lastPathComponent
                if !validFileNames.contains(fileName) {
                    try FileManager.default.removeItem(at: fileURL)
                    print("🗑️ Cleaned up orphaned file: \(fileName)")
                }
            }
        } catch {
            print("⚠️ Error cleaning up orphaned files: \(error)")
        }
    }
}