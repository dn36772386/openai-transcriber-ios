import SwiftUI
import AVFoundation
import Foundation
import Combine // Combineをインポート
import UniformTypeIdentifiers

// MARK: - Color Palette
extension Color {
    static let appBackground = Color(hex: "#F9FAFB")
    static let sidebarBackground = Color(hex: "#ffffff")
    static let accent = Color(hex: "#6b7280") // 変更: 薄いグレーに
    static let icon = Color(hex: "#374151")
    static let border = Color(hex: "#e5e7eb")
    static let danger = Color(hex: "#6b7280") // 変更: 薄いグレーに
    static let cardBackground = Color(hex: "#ffffff")
    static let textPrimary = Color(hex: "#1F2937")
    static let textSecondary = Color(hex: "#6b7280")
    static let playerBackground = Color(hex: "#1F2937")
    static let playerText = Color(hex: "#ffffff")
    static let iconOutline = Color(hex: "#374151").opacity(0.8)  // 少し透明度を加える

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Notification Name
extension Notification.Name {
    /// 文字起こし処理が完了したときに送信される通知
    static let transcriptionDidFinish = Notification.Name("transcriptionDidFinishNotification")
}

// MARK: - Sidebar Enum
enum SidebarMenuItemType: CaseIterable {
    case transcribe, proofread, copy, audioDownload, settings
}

// MARK: - Main View
struct ContentView: View {
    @State private var proxy = RecorderProxy()
    @StateObject private var recorder = AudioEngineRecorder()
    @StateObject private var audioPlayerDelegate = AudioPlayerDelegateWrapper() // 1つのみ残す
    @State private var showPermissionAlert = false
    @State private var showSidebar = UIDevice.current.userInterfaceIdiom != .phone
    @State private var modeIsManual = false
    @State private var activeMenuItem: SidebarMenuItemType? = .transcribe
    @State private var showSettings = false
    @State private var transcriptLines: [TranscriptLine] = []
    @State private var currentPlayingURL: URL?
    @State private var audioPlayer: AVAudioPlayer?
    @StateObject private var historyManager = HistoryManager.shared
    // @StateObject private var audioPlayerDelegate = AudioPlayerDelegateWrapper() ← この行を削除
    @State private var isCancelling = false
    @State private var transcriptionTasks: [URL: UUID] = [:] // URLと行IDのマッピング
    @State private var cancellables = Set<AnyCancellable>()
    @State private var showFilePicker = false
    @StateObject private var fileProcessor = AudioFileProcessor()
    @State private var showProcessingProgress = false
    @State private var showFormatAlert = false
    @State private var formatAlertMessage = ""

    private let client = OpenAIClient()
    
    var body: some View {
        ZStack(alignment: .leading) {
            NavigationView {
                VStack(spacing: 0) {
                    // メインコンテンツ
                    MainContentView(
                        modeIsManual: $modeIsManual,
                        isRecording: $recorder.isRecording,
                        transcriptLines: $transcriptLines,
                        audioPlayerURL: $currentPlayingURL, // これはMainContentViewで直接は使わないが、将来のために残す
                        audioPlayer: $audioPlayer,          // これも同様
                        onLineTapped: self.playFrom,        // 行タップ時の再生開始
                        playNextSegmentCallback: self.playNextSegment // コールバックを渡す
                    )
                    
                    // 下部の再生バー (CompactAudioPlayerViewを含む)
                    if currentPlayingURL != nil || !transcriptLines.isEmpty {
                        CompactAudioPlayerView(
                            url: $currentPlayingURL,
                            player: $audioPlayer,
                            onPlaybackFinished: self.playNextSegment, // 再生終了時にplayNextSegmentを呼ぶ
                            playerDelegate: audioPlayerDelegate // デリゲートを渡す
                        )
                        .padding(.bottom, 8)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        HamburgerButton(showSidebar: $showSidebar)
                    }
                    ToolbarItem(placement: .principal) {
                        // タイトル表示（再生バーがない場合）
                        if currentPlayingURL == nil && transcriptLines.isEmpty {
                            Text("Transcriber").font(.headline)
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 15) {
                            if !recorder.isRecording {
                                Toggle("", isOn: $modeIsManual)
                                    .labelsHidden()
                                    .tint(Color.accent)
                                Text(modeIsManual ? "manual" : "auto")
                                    .font(.caption)
                                    .foregroundColor(Color.textSecondary)
                                
                                Button {
                                    showFilePicker = true
                                } label: {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundColor(Color.accent)
                                }
                            }

                            if recorder.isRecording {
                                Button {
                                    finishRecording()
                                } label: {
                                    Image(systemName: "checkmark.circle")  // .fill を削除
                                        .font(.system(size: 22, weight: .light))  // weight を .light に
                                        .foregroundColor(Color.accent)
                                }
                                Button {
                                    cancelRecording()
                                } label: {
                                    Image(systemName: "xmark.circle")  // .fill を削除
                                        .font(.system(size: 22, weight: .light))  // weight を .light に
                                        .foregroundColor(Color.danger)
                                }
                            } else {
                                Button {
                                    startRecording()
                                } label: {
                                    Image(systemName: "mic.circle")  // mic.fill から mic.circle に変更
                                        .font(.system(size: 22, weight: .light))  // サイズと weight を調整
                                        .foregroundColor(Color.accent)
                                }
                            }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .background(Color.appBackground.edgesIgnoringSafeArea(.all))
            }
            .navigationViewStyle(StackNavigationViewStyle())

            // Sidebar
            if showSidebar {
                SidebarView(
                    showSidebar: $showSidebar,
                    activeMenuItem: $activeMenuItem,
                    showSettings: $showSettings,
                    onLoadHistoryItem: self.loadHistoryItem,
                    onPrepareNewSession: { self.prepareNewTranscriptionSession(saveCurrentSession: true) }
                )
                .transition(.move(edge: .leading))
                .zIndex(1)
            }

            // Sidebar background overlay for phone
            if showSidebar && UIDevice.current.userInterfaceIdiom == .phone {
                Color.black.opacity(0.35)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false } }
                    .zIndex(0.5)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: AudioFormatHandler.supportedFormats,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    processImportedFileWithFormatSupport(url)
                }
            case .failure(let error):
                formatAlertMessage = "ファイル選択エラー: \(error.localizedDescription)"
                showFormatAlert = true
            }
        }
        .sheet(isPresented: $showProcessingProgress) {
            VStack(spacing: 20) {
                Text("音声ファイルを処理中...")
                    .font(.headline)
                
                ProgressView(value: fileProcessor.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding(.horizontal)
                
                Text("\(Int(fileProcessor.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(40)
            .interactionDisabled(true)
        }
        .alert("フォーマットエラー", isPresented: $showFormatAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(formatAlertMessage)
        }
        .onAppear {
            if KeychainHelper.shared.apiKey() == nil {
                DispatchQueue.main.async { showSettings = true }
            }
            
            // RecorderProxyのセットアップ
            proxy.onSegment = { url, start in
                self.handleSegmentInBackground(url: url, start: start)
            }
            recorder.delegate = proxy
            
            // AudioPlayerDelegateのセットアップ
            audioPlayerDelegate.onPlaybackFinished = {
                playNextSegment()
            }
            
            // NotificationCenterの監視セットアップ
            NotificationCenter.default.publisher(for: .transcriptionDidFinish)
                .receive(on: DispatchQueue.main)
                .sink { notification in
                    self.handleTranscriptionResult(notification: notification)
                }
                .store(in: &cancellables)
        }
        .alert("マイクへのアクセスが許可されていません", isPresented: $showPermissionAlert) {
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("音声録音を行うには、設定アプリの「プライバシー > マイク」で本アプリを許可してください。")
        }
    }

    private func startRecording() {
        guard !recorder.isRecording else { return }
        requestMicrophonePermission()
    }

    private func finishRecording() {
        Debug.log("✅ finish tapped")
        isCancelling = false
        recorder.stop()
        // 履歴保存は明示的に行う
        historyManager.addHistoryItem(lines: transcriptLines, fullAudioURL: currentPlayingURL)
    }

    private func cancelRecording() {
        Debug.log("❌ cancel tapped")
        isCancelling = true
        recorder.cancel()
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        transcriptionTasks.removeAll() // キャンセル時は進行中のタスクもクリア
    }

    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { granted in
            handlePermissionResult(granted)
        }
    }

    private func handlePermissionResult(_ granted: Bool) {
        DispatchQueue.main.async {
            if granted {
                do {
                    isCancelling = false
                    // 新規録音開始時は保存せずにクリア
                    self.prepareNewTranscriptionSession(saveCurrentSession: false)
                    transcriptionTasks.removeAll()
                    print("Starting recorder with isManual: \(self.modeIsManual)")
                    try recorder.start(isManual: self.modeIsManual)
                } catch {
                    print("[Recorder] start failed:", error.localizedDescription)
                }
            } else {
                showPermissionAlert = true
            }
        }
    }

    // バックグラウンド対応のセグメントハンドラ
    @MainActor
    private func handleSegmentInBackground(url: URL, start: Date) {
        guard !isCancelling else {
            Debug.log("🚫 Segment ignored due to cancel.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        print("🎧 Segment file path:", url.path)

        // 最初のセグメントなら、それを再生対象として設定
        if self.currentPlayingURL == nil { self.currentPlayingURL = url }

        let newLine = TranscriptLine(id: UUID(), time: start, text: "…文字起こし中…", audioURL: url)
        self.transcriptLines.append(newLine)
        self.transcriptionTasks[url] = newLine.id

        Task { @MainActor in
            do {
                // 新しい transcribeInBackground を呼び出す (これは例外を投げる可能性がある)
                try client.transcribeInBackground(url: url, started: start)
                // 成功すれば、タスクは AppDelegate に渡され、結果は通知で返ってくる
            } catch {
                // タスク開始前のエラー（ファイルサイズ、APIキー、一時ファイル書き込みなど）
                print("❌ Failed to start background task: \(error.localizedDescription)")
                if let lineId = self.transcriptionTasks[url],
                   let index = self.transcriptLines.firstIndex(where: { $0.id == lineId }) {
                    self.transcriptLines[index].text = "⚠️ 開始エラー: \(error.localizedDescription)"
                    self.transcriptionTasks.removeValue(forKey: url)
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
    
    // 通知を受け取ってUIを更新するハンドラ
    @MainActor
    private func handleTranscriptionResult(notification: Notification) {
        guard let originalURL = notification.object as? URL,
              let lineId = self.transcriptionTasks[originalURL],
              let index = self.transcriptLines.firstIndex(where: { $0.id == lineId }) else {
            print("🔔 Received notification for unknown/completed task: \(notification.object ?? "N/A")")
            return
        }

        if let error = notification.userInfo?["error"] as? Error {
            self.transcriptLines[index].text = "⚠️ \(error.localizedDescription)"
            // エラー時は originalURL を削除しても良いが、HistoryManager との連携を考慮
        } else if let text = notification.userInfo?["text"] as? String {
            self.transcriptLines[index].text = text
        } else {
             self.transcriptLines[index].text = "⚠️ 不明なエラー"
        }
        self.transcriptionTasks.removeValue(forKey: originalURL)
    }

    // 次のセグメントを再生する (CompactAudioPlayerViewから呼ばれる)
    private func playNextSegment() {
        Debug.log("🎵 playNextSegment called")
        Debug.log("📊 Current audioPlayer: \(audioPlayer != nil ? "exists" : "nil")")
        Debug.log("📊 Current delegate: \(audioPlayer?.delegate != nil ? "exists" : "nil")")
        
        guard let currentURL = currentPlayingURL else {
            Debug.log("❌ No current playing URL")
            return
        }
        
        Debug.log("📍 Current URL: \(currentURL.lastPathComponent)")
        Debug.log("📊 Transcript lines count: \(transcriptLines.count)")
        
        // デバッグ: 全てのtranscriptLinesのURLを表示
        for (index, line) in transcriptLines.enumerated() {
            Debug.log("  [\(index)] \(line.audioURL?.lastPathComponent ?? "no URL")")
        }
        
        guard let currentIndex = transcriptLines.firstIndex(where: { $0.audioURL == currentURL }) else {
            Debug.log("❌ Current URL not found in transcript lines")
            currentPlayingURL = nil
            return
        }
        
        Debug.log("📍 Current index: \(currentIndex), Total lines: \(transcriptLines.count)")
        
        let nextIndex = currentIndex + 1
        if transcriptLines.indices.contains(nextIndex) {
            if let nextURL = transcriptLines[nextIndex].audioURL {
                Debug.log("✅ Playing next segment: \(nextURL.lastPathComponent)")
                playFrom(url: nextURL) // 次のセグメントを再生
            } else {
                Debug.log("❌ Next segment has no audio URL")
                currentPlayingURL = nil
                audioPlayer?.stop()
                audioPlayer = nil
            }
        } else {
            Debug.log("🏁 Reached end of segments")
            currentPlayingURL = nil
            audioPlayer?.stop()
            audioPlayer = nil
        }
    }
    
    /// 指定されたURLのオーディオファイルを再生する
    /// - Parameter url: 再生するオーディオファイルのURL
    private func playFrom(url: URL) {
        print("🛠 🎵 playFrom called with URL: \(url.lastPathComponent)")
        
        // ファイルサイズを確認
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber {
            print("🛠 📊 Audio file size: \(fileSize.intValue) bytes")
        }
        
        // ファイルの存在確認
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("🛠 ❌ Audio file does not exist: \(url.path)")
            return
        }
        
        do {
            // 既存のプレイヤーがあれば停止
            audioPlayer?.stop()
            
            // 再生セッションの設定
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            print("🛠 ✅ Audio session configured for playback")
            
            // 音声ファイルの検証
            let tempPlayer = try AVAudioPlayer(contentsOf: url)
            tempPlayer.prepareToPlay()
            let audioDuration = tempPlayer.duration
            print("🛠 ✅ Audio file validation successful - Duration: \(String(format: "%.2f", audioDuration))s")
            
            // 新しいプレイヤーを作成
            audioPlayer = tempPlayer
            print("🛠 🎧 Player created - Duration: \(String(format: "%.2f", audioDuration))s, Channels: \(tempPlayer.numberOfChannels)")
            
            // ★重要：audioPlayerDelegateを設定（selfではなく）
            audioPlayer?.delegate = audioPlayerDelegate
            print("🛠 🎧 Delegate set: \(audioPlayer?.delegate != nil ? "YES" : "NO")")
            
            // ★重要：currentPlayingURLを更新する前に再生を開始
            let playSuccess = audioPlayer?.play() ?? false
            if playSuccess {
                print("🛠 ▶️ Playback started successfully for: \(url.lastPathComponent)")
                // 再生開始後にcurrentPlayingURLを更新（これでCompactAudioPlayerViewが更新される）
                currentPlayingURL = url
            } else {
                print("🛠 ❌ Failed to start playback for: \(url.lastPathComponent)")
                audioPlayer = nil
            }
            
        } catch {
            print("❌ Playback Error or Failed to load audio:", error.localizedDescription)
            audioPlayer = nil
            currentPlayingURL = nil
        }
    }
    
    // 新規セッション準備（履歴保存フラグを追加）
    private func prepareNewTranscriptionSession(saveCurrentSession: Bool = true) {
        if saveCurrentSession && (!transcriptLines.isEmpty || currentPlayingURL != nil) {
            historyManager.addHistoryItem(lines: transcriptLines, fullAudioURL: currentPlayingURL)
        }
        
        // セッションをリセット
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isCancelling = false
    }

    // 履歴読み込み（修正版）
    private func loadHistoryItem(_ historyItem: HistoryItem) {
        // 現在のセッションを保存（空でない場合のみ）
        if !transcriptLines.isEmpty || currentPlayingURL != nil {
            historyManager.addHistoryItem(lines: transcriptLines, fullAudioURL: currentPlayingURL)
        }
        
        // ★履歴読み込み時は保存しないように修正
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isCancelling = false
        
        // 履歴アイテムをロード
        self.transcriptLines = historyItem.getTranscriptLines(documentsDirectory: historyManager.documentsDirectory)

        // 再生URLを設定（全体音声があればそれを、なければ最初のセグメント）
        if let fullAudio = historyItem.getFullAudioURL(documentsDirectory: historyManager.documentsDirectory) {
            self.currentPlayingURL = fullAudio
        } else if let firstSegment = self.transcriptLines.first?.audioURL {
            self.currentPlayingURL = firstSegment
        }
        
        // プレイヤーを準備 (最初のセグメントで)
        if let url = self.currentPlayingURL {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.delegate = audioPlayerDelegate // ★修正：audioPlayerDelegateを使用
                audioPlayer?.prepareToPlay()
            } catch {
                print("❌ Failed to load history audio:", error.localizedDescription)
                audioPlayer = nil
                currentPlayingURL = nil
            }
        }
        
        // Sidebarを閉じる (Phoneの場合)
        if UIDevice.current.userInterfaceIdiom == .phone {
            withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
        }
    }
    
    // ファイルインポート処理
    private func processImportedFile(_ url: URL) {
        Task {
            do {
                showProcessingProgress = true
                
                // 新しいセッションを準備
                prepareNewTranscriptionSession(saveCurrentSession: true)
                
                // ファイルを処理
                let result = try await fileProcessor.processFile(at: url)
                
                // 各セグメントを文字起こし
                for (index, segment) in result.segments.enumerated() {
                    let startDate = Date(timeIntervalSinceNow: -result.totalDuration + segment.startTime)
                    
                    // 最初のセグメントを再生対象に設定
                    if index == 0 {
                        self.currentPlayingURL = segment.url
                    }
                    
                    // TranscriptLineを追加
                    let newLine = TranscriptLine(
                        id: UUID(),
                        time: startDate,
                        text: "…文字起こし中…",
                        audioURL: segment.url
                    )
                    self.transcriptLines.append(newLine)
                    self.transcriptionTasks[segment.url] = newLine.id
                    
                    // Whisperに送信
                    try client.transcribeInBackground(
                        url: segment.url,
                        started: startDate
                    )
                }
                
                showProcessingProgress = false
                
            } catch {
                showProcessingProgress = false
                print("❌ File processing error: \(error)")
                // エラーアラートを表示
            }
        }
    }
}

// MARK: - Hamburger Button
struct HamburgerButton: View {
    @Binding var showSidebar: Bool
    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } }) {
            Image(systemName: "line.horizontal.3")
                .imageScale(.large)
                .foregroundColor(Color.icon)
        }
    }
}

// MARK: - Sidebar
struct SidebarView: View {
    @Binding var showSidebar: Bool
    @Binding var activeMenuItem: SidebarMenuItemType?
    @Binding var showSettings: Bool
    var onLoadHistoryItem: (HistoryItem) -> Void
    var onPrepareNewSession: () -> Void
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var selectedHistoryItem: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcriber")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 50)

            VStack(alignment: .leading, spacing: 5) {
                SidebarMenuItem(icon: "mic", text: "文字起こし", type: .transcribe, activeMenuItem: $activeMenuItem, action: {
                    if activeMenuItem == .transcribe {
                        onPrepareNewSession()
                    }
                    activeMenuItem = .transcribe
                    closeSidebar()
                })
                SidebarMenuItem(icon: "text.badge.checkmark", text: "校正", type: .proofread, activeMenuItem: $activeMenuItem, action: { activeMenuItem = .proofread; closeSidebar() })
                SidebarMenuItem(icon: "doc.on.doc", text: "コピー", type: .copy, activeMenuItem: $activeMenuItem, action: { activeMenuItem = .copy; closeSidebar() })
                SidebarMenuItem(icon: "arrow.down.circle", text: "音声DL", type: .audioDownload, activeMenuItem: $activeMenuItem, action: { activeMenuItem = .audioDownload; closeSidebar() })
                SidebarMenuItem(icon: "gearshape.fill", text: "設定", type: .settings, activeMenuItem: $activeMenuItem, action: {
                    showSettings = true
                    closeSidebar()
                })
            }
            .padding(.vertical, 10)

            Divider().background(Color.border).padding(.vertical, 5)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("履歴")
                        .font(.system(size: 14))
                        .foregroundColor(Color.textSecondary)
                    Spacer()
                    Button {
                        historyManager.clearAllHistory()
                    } label: {
                        Image(systemName: "trash").foregroundColor(Color.icon)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 14).padding(.vertical, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(historyManager.historyItems) { item in
                            HStack {
                                Text(item.date.toLocaleString())
                                    .font(.system(size: 13)).foregroundColor(Color.icon)
                                Spacer()
                                if selectedHistoryItem == item.id {
                                    Button {
                                        historyManager.deleteHistoryItem(id: item.id)
                                    } label: {
                                        Image(systemName: "trash.fill").foregroundColor(Color.danger)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .background(selectedHistoryItem == item.id ? Color.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(4)
                            .onTapGesture { 
                                selectedHistoryItem = item.id 
                                onLoadHistoryItem(item)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(width: 240)
        .background(Color.sidebarBackground)
        .edgesIgnoringSafeArea(UIDevice.current.userInterfaceIdiom == .phone ? .vertical : [])
    }

    private func closeSidebar() {
        if UIDevice.current.userInterfaceIdiom == .phone {
            withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
        }
    }
}

extension Date {
    func toLocaleString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm:ss"
        return formatter.string(from: self)
    }
}

struct SidebarMenuItem: View {
    let icon: String
    let text: String
    let type: SidebarMenuItemType
    @Binding var activeMenuItem: SidebarMenuItemType?
    let action: () -> Void
    var isActive: Bool { activeMenuItem == type }

    var body: some View {
        Button(action: { action() }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .light))  // weight を統一
                    .frame(width: 20, alignment: .center)
                    .foregroundColor(isActive ? Color.accent : Color.iconOutline)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(isActive ? Color.textPrimary : Color.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isActive ? Color.accent.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .padding(.horizontal, 8).padding(.vertical, 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Compact Audio Player (下部バー用)
struct CompactAudioPlayerView: View {
    @Binding var url: URL?
    @Binding var player: AVAudioPlayer?
    var onPlaybackFinished: (() -> Void)?
    var playerDelegate: AudioPlayerDelegateWrapper // 型を指定

    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var duration: TimeInterval = 0.0
    @State private var currentTime: TimeInterval = 0.0
    @State private var isEditingSlider = false 

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 15) {
            Button { togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.circle" : "play.circle")  // .fill を削除
                    .font(.system(size: 24, weight: .light))  // サイズと weight を調整
                    .foregroundColor(Color.accent)
                    .frame(width: 44, height: 44)
            }
            
            Slider(value: $progress, in: 0...1) { editing in
                isEditingSlider = editing
                if !editing {
                    player?.currentTime = progress * duration
                    // 再生中だった場合は再生再開
                    if isPlaying && !(player?.isPlaying ?? false) {
                       player?.play()
                    }
                } else if isPlaying {
                    // スライダー操作中は一時停止
                    player?.pause()
                }
            }
            .tint(Color.accent)

            Text(formatTime(currentTime))
                .font(.caption)
                .foregroundColor(.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appBackground)
        .onReceive(timer) { _ in updateProgress() }
        .onChange(of: url) { _, newURL in
            // URLが変更されたらプレイヤーをリセット
            resetPlayer(url: newURL) 
        }
        // player の状態を監視して isPlaying を更新
        .onChange(of: player?.isPlaying) { _, newValue in
             if !isEditingSlider { // スライダー編集中でなければ
                isPlaying = newValue ?? false
             }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            do {
                // バックグラウンド再生を有効にする設定
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP])
                try AVAudioSession.sharedInstance().setActive(true)
                player.play()
                isPlaying = true
            } catch { print("❌ Playback Error:", error.localizedDescription) }
        }
    }
    
    private func updateProgress() {
        guard let player = player, !isEditingSlider else { return }

        currentTime = player.currentTime
        duration = player.duration
        let currentPlayingState = player.isPlaying

        if currentPlayingState {
            progress = (duration > 0) ? (currentTime / duration) : 0
        }

        // より正確な再生終了の検出
        if isPlaying && !currentPlayingState && duration > 0 {
            // 再生位置が最後に近いか、正確に最後にある場合
            if currentTime >= duration - 0.1 || progress >= 0.99 {
                Debug.log("🏁 Timer detected playback finished - progress: \(progress), time: \(currentTime)/\(duration)")
                progress = 1.0
                currentTime = duration
                isPlaying = false
                
                // デリゲートが機能しない場合のバックアップ
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.onPlaybackFinished?()
                }
            }
        } else if isPlaying != currentPlayingState {
            isPlaying = currentPlayingState
        }
    }
    
    private func resetPlayer(url: URL?) {
        Debug.log("🔄 resetPlayer called with URL: \(url?.lastPathComponent ?? "nil")")
        
        // 同じURLで既にプレイヤーが存在し、準備ができている場合はスキップ
        if let currentPlayer = player,
           let currentURL = currentPlayer.url,
           let newURL = url,
           currentURL == newURL {
            Debug.log("✅ Same URL already loaded, skipping resetPlayer")
            // 状態だけ更新
            duration = currentPlayer.duration
            currentTime = currentPlayer.currentTime
            isPlaying = currentPlayer.isPlaying
            progress = duration > 0 ? currentTime / duration : 0.0
            return
        }
        
        // URLが変わった場合のみプレイヤーを停止・再作成
        if player != nil {
            Debug.log("🛑 Stopping existing player")
            player?.stop()
            player?.delegate = nil
        }
        
        // 状態をリセット
        isPlaying = false
        progress = 0.0
        currentTime = 0.0
        duration = 0.0
        isEditingSlider = false
        
        guard let urlToPlay = url else {
            Debug.log("🗑️ No URL provided, clearing player")
            self.player = nil
            return
        }
        
        do {
            Debug.log("🆕 Creating new player for: \(urlToPlay.lastPathComponent)")
            let newPlayer = try AVAudioPlayer(contentsOf: urlToPlay)
            self.player = newPlayer
            
            // ★重要：playerDelegateを設定
            self.player?.delegate = playerDelegate
            Debug.log("✅ Delegate set in resetPlayer")
            
            self.player?.prepareToPlay()
            self.duration = self.player?.duration ?? 0.0
            Debug.log("✅ Player prepared - Duration: \(self.duration)s")
            
        } catch {
            Debug.log("❌ Failed to load audio: \(error.localizedDescription)")
            self.player = nil
        }
    }
}


// MARK: - Main Content
struct MainContentView: View {
    @Binding var modeIsManual: Bool
    @Binding var isRecording: Bool
    @Binding var transcriptLines: [TranscriptLine]
    @Binding var audioPlayerURL: URL? // Keep for potential future use or decoupling
    @Binding var audioPlayer: AVAudioPlayer? // Keep for potential future use or decoupling
    let onLineTapped: (URL) -> Void
    let playNextSegmentCallback: () -> Void // Keep this if MainContent might influence playback

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(lines: $transcriptLines, onLineTapped: onLineTapped)
                .padding(.top, 10)
                .padding(.horizontal, 10)
        }
        .background(Color.appBackground.edgesIgnoringSafeArea(.all))
    }
}

// MARK: - AudioPlayerDelegateWrapper
class AudioPlayerDelegateWrapper: NSObject, ObservableObject, AVAudioPlayerDelegate {
    var onPlaybackFinished: (() -> Void)?
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Debug.log("🏁 AVAudioPlayerDelegate: Playback finished (success: \(flag))")
        DispatchQueue.main.async {
            self.onPlaybackFinished?()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Debug.log("❌ AVAudioPlayerDelegate: Decode error: \(error?.localizedDescription ?? "Unknown")")
    }
}

// MARK: - ContentView Extension for File Import
extension ContentView {
    
    // ファイルインポート処理（拡張版）
    func processImportedFileWithFormatSupport(_ url: URL) {
        // フォーマット検証
        let validation = AudioFormatHandler.validateFormat(url: url)
        
        guard validation.isValid else {
            // エラーアラート表示
            showFormatError(validation.error ?? "不明なエラー")
            return
        }
        
        // メタデータ表示（オプション）
        if let metadata = AudioFormatHandler.getAudioMetadata(from: url) {
            print("📊 Audio Metadata:")
            print("  Duration: \(metadata.formattedDuration)")
            print("  Sample Rate: \(metadata.sampleRate) Hz")
            print("  Channels: \(metadata.channelCount)")
            print("  Bit Rate: \(metadata.formattedBitRate)")
            print("  File Size: \(metadata.formattedFileSize)")
            print("  Codec: \(metadata.codec)")
        }
        
        // プログレス表示開始
        showProcessingProgress = true
        
        // 音声抽出/変換処理
        AudioFormatHandler.extractAudio(from: url) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let processedURL):
                    // 抽出/変換成功後、無音分割処理へ
                    self?.performSilenceSplitting(processedURL, originalURL: url)
                    
                case .failure(let error):
                    self?.showProcessingProgress = false
                    self?.showFormatError(error.localizedDescription)
                }
            }
        }
    }
    
    // 無音分割処理の実行
    private func performSilenceSplitting(_ url: URL, originalURL: URL) {
        Task {
            do {
                // 新しいセッションを準備
                prepareNewTranscriptionSession(saveCurrentSession: true)
                
                // ファイルを処理
                let result = try await fileProcessor.processFile(at: url)
                
                // 元のファイル名を表示用に保存
                let originalFileName = originalURL.lastPathComponent
                
                // 各セグメントを文字起こし
                for (index, segment) in result.segments.enumerated() {
                    let startDate = Date(timeIntervalSinceNow: -result.totalDuration + segment.startTime)
                    
                    // 最初のセグメントを再生対象に設定
                    if index == 0 {
                        self.currentPlayingURL = segment.url
                    }
                    
                    // TranscriptLineを追加
                    let newLine = TranscriptLine(
                        id: UUID(),
                        time: startDate,
                        text: "…文字起こし中… [\(originalFileName) - セグメント\(index + 1)]",
                        audioURL: segment.url
                    )
                    self.transcriptLines.append(newLine)
                    self.transcriptionTasks[segment.url] = newLine.id
                    
                    // Whisperに送信
                    try client.transcribeInBackground(
                        url: segment.url,
                        started: startDate
                    )
                }
                
                showProcessingProgress = false
                
                // 一時ファイルのクリーンアップ（変換されたファイルの場合）
                if url != originalURL {
                    try? FileManager.default.removeItem(at: url)
                }
                
            } catch {
                showProcessingProgress = false
                showFormatError("処理エラー: \(error.localizedDescription)")
            }
        }
    }
    
    // エラーアラート表示
    private func showFormatError(_ message: String) {
        formatAlertMessage = message
        showFormatAlert = true
    }
}

// MARK: - Enhanced File Picker View
struct EnhancedFilePickerButton: View {
    @Binding var showFilePicker: Bool
    @State private var showFormatInfo = false
    
    var body: some View {
        HStack(spacing: 8) {
            Button {
                showFilePicker = true
            } label: {
                Label("音声をインポート", systemImage: "square.and.arrow.down")
                    .font(.system(size: 16))
            }
            
            Button {
                showFormatInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showFormatInfo) {
            SupportedFormatsView()
        }
    }
}

// MARK: - Supported Formats Info View
struct SupportedFormatsView: View {
    @Environment(\.dismiss) private var dismiss
    
    private let formats = [
        ("音声ファイル", ["WAV", "MP3", "M4A/AAC", "AIFF", "FLAC"]),
        ("動画ファイル", ["MP4", "MOV", "その他（音声トラック付き）"]),
        ("制限事項", ["OGG Vorbisは変換が必要", "WEBMは一部のみ対応", "DRM保護されたファイルは非対応"])
    ]
    
    var body: some View {
        NavigationView {
            List {
                ForEach(formats, id: \.0) { section in
                    Section(header: Text(section.0)) {
                        ForEach(section.1, id: \.self) { format in
                            HStack {
                                Image(systemName: formatIcon(for: format))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 30)
                                Text(format)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                }
                
                Section(header: Text("ヒント")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("長い録音は自動的に分割されます", systemImage: "scissors")
                        Label("動画から音声が自動抽出されます", systemImage: "film")
                        Label("最適な品質のため16kHzに変換されます", systemImage: "waveform")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("対応フォーマット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
    
    private func formatIcon(for format: String) -> String {
        if format.contains("WAV") || format.contains("AIFF") {
            return "waveform"
        } else if format.contains("MP") || format.contains("AAC") {
            return "music.note"
        } else if format.contains("MOV") || format.contains("動画") {
            return "film"
        } else if format.contains("DRM") {
            return "lock"
        } else {
            return "doc"
        }
    }
}

// MARK: - File Import Configuration
struct FileImportConfiguration {
    static let allowedContentTypes: [UTType] = AudioFormatHandler.supportedFormats
    
    static let importOptions: UIDocumentPickerViewController.Options = [
        .shouldShowFileExtensions,
        .treatPackagesAsDirectories
    ]
}

// MARK: - Preview (Optional)
#Preview {
    ContentView()
}