import SwiftUI
import AVFoundation
import Foundation
import Combine // Combineをインポート

// MARK: - Color Palette
extension Color {
    static let appBackground = Color(hex: "#F9FAFB")
    static let sidebarBackground = Color(hex: "#ffffff")
    static let accent = Color(hex: "#10B981")
    static let icon = Color(hex: "#374151")
    static let border = Color(hex: "#e5e7eb")
    static let danger = Color(hex: "#dc2626")
    static let cardBackground = Color(hex: "#ffffff")
    static let textPrimary = Color(hex: "#1F2937")
    static let textSecondary = Color(hex: "#6b7280")
    static let playerBackground = Color(hex: "#1F2937")
    static let playerText = Color(hex: "#ffffff")

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
    @State private var showPermissionAlert = false
    @State private var showSidebar = UIDevice.current.userInterfaceIdiom != .phone
    @State private var modeIsManual = false
    @State private var activeMenuItem: SidebarMenuItemType? = .transcribe
    @State private var showSettings = false
    @State private var transcriptLines: [TranscriptLine] = []
    @State private var currentPlayingURL: URL?
    @State private var audioPlayer: AVAudioPlayer?
    @StateObject private var historyManager = HistoryManager.shared
    @State private var isCancelling = false
    @State private var transcriptionTasks: [URL: UUID] = [:] // URLと行IDのマッピング
    @State private var cancellables = Set<AnyCancellable>() // Combineの購読管理

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
                            onPlaybackFinished: self.playNextSegment // 再生終了時にplayNextSegmentを呼ぶ
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
                            }

                            if recorder.isRecording {
                                Button {
                                    finishRecording()
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(Color.accent)
                                }
                                Button {
                                    cancelRecording()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(Color.danger)
                                }
                            } else {
                                Button {
                                    startRecording()
                                } label: {
                                    Image(systemName: "mic.fill")
                                        .font(.system(size: 18))
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
                    onPrepareNewSession: self.prepareNewTranscriptionSession
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
        .onAppear {
            if KeychainHelper.shared.apiKey() == nil {
                DispatchQueue.main.async { showSettings = true }
            }
            // RecorderProxyのセットアップ
            proxy.onSegment = { url, start in
                self.handleSegmentInBackground(url: url, start: start)
            }
            recorder.delegate = proxy

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

    // 指定URLから再生を開始する
    private func playFrom(url: URL) {
        currentPlayingURL = url // 再生中のURLを更新 (これによりCompactAudioPlayerViewも更新される)
        
        // AVAudioPlayerを準備して再生
        do {
            // 既存のプレイヤーがあれば停止
            audioPlayer?.stop()
            
            // 再生セッションの設定
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            // 新しいプレイヤーを作成
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play() // 再生開始
            
        } catch {
            print("❌ Playback Error or Failed to load audio:", error.localizedDescription)
            audioPlayer = nil
            currentPlayingURL = nil
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
        // 最後のセグメントURLか、管理しているURLを渡す。今はcurrentPlayingURLで代用。
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
                    transcriptLines.removeAll() // 新規録音開始時にリストをクリア
                    currentPlayingURL = nil     // 再生URLもクリア
                    audioPlayer?.stop()         // プレイヤーも停止
                    audioPlayer = nil
                    transcriptionTasks.removeAll() // タスクもクリア
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
        guard let currentURL = currentPlayingURL else { return }
        
        guard let currentIndex = transcriptLines.firstIndex(where: { $0.audioURL == currentURL }) else {
            currentPlayingURL = nil // 見つからなければ再生終了
            return
        }

        let nextIndex = currentIndex + 1
        if transcriptLines.indices.contains(nextIndex),
           let nextURL = transcriptLines[nextIndex].audioURL {
            playFrom(url: nextURL) // 次のセグメントを再生
        } else {
            currentPlayingURL = nil // 次がなければ再生終了
            audioPlayer?.stop()
            audioPlayer = nil
        }
    }
    
    // 新規セッション準備
    private func prepareNewTranscriptionSession() {
        if !transcriptLines.isEmpty || currentPlayingURL != nil {
            historyManager.addHistoryItem(lines: transcriptLines, fullAudioURL: currentPlayingURL)
        }
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isCancelling = false
    }

    // 履歴読み込み
    private func loadHistoryItem(_ historyItem: HistoryItem) {
        // 現在のセッションを保存（必要であれば）
        prepareNewTranscriptionSession()
        
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
                    .font(.system(size: 16))
                    .frame(width: 20, alignment: .center)
                    .foregroundColor(isActive ? Color.accent : Color.icon)
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

    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var duration: TimeInterval = 0.0
    @State private var currentTime: TimeInterval = 0.0
    @State private var isEditingSlider = false 

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 15) {
            Button { togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
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
        .onChange(of: url) {
            // URLが変更されたらプレイヤーをリセット
            resetPlayer(url: url) 
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
        duration = player.duration // 常に最新の duration を取得
        let currentPlayingState = player.isPlaying

        if currentPlayingState {
             progress = (duration > 0) ? (currentTime / duration) : 0
        }

        // isPlaying の状態と実際の再生状態が異なり、かつ再生が終了した場合
        if isPlaying && !currentPlayingState && duration > 0 && abs(currentTime - duration) < 0.15 {
            progress = 1.0
            currentTime = duration 
            isPlaying = false // isPlaying を false に更新
            DispatchQueue.main.async {
                self.onPlaybackFinished?()
            }
        } else if isPlaying != currentPlayingState {
             // 通常の再生/一時停止で状態が食い違った場合、実際の状態に合わせる
            isPlaying = currentPlayingState
        }
    }
    
    private func resetPlayer(url: URL?) {
        player?.stop()
        isPlaying = false
        progress = 0.0
        currentTime = 0.0
        duration = 0.0
        isEditingSlider = false
        
        guard let urlToPlay = url else {
            self.player = nil
            return
        }
        
        do {
            self.player = try AVAudioPlayer(contentsOf: urlToPlay)
            self.player?.prepareToPlay()
            self.duration = self.player?.duration ?? 0.0
            // URLがリセットされたときに自動再生はしない（タップや次のセグメント再生で開始）
        } catch {
            print("❌ Failed to load audio:", error.localizedDescription)
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

// MARK: - Preview (Optional)
#Preview {
    ContentView()
}