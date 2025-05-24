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
    static let playerBackground = Color(hex: "#1F2937") // これはCompactAudioPlayerViewの旧背景色ですが、Color拡張には残しておきます
    static let playerText = Color(hex: "#ffffff")     // これも同様

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

// MARK: - Sidebar Enum (ContentViewの外に移動)
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
        ZStack(alignment: .leading) { // ZStack を alignment: .leading に変更
            NavigationView {
                VStack(spacing: 0) {
                    // メインコンテンツ (再生バーより先に)
                    MainContentView(
                        modeIsManual: $modeIsManual,
                        isRecording: $recorder.isRecording,
                        transcriptLines: $transcriptLines,
                        audioPlayerURL: $currentPlayingURL,
                        audioPlayer: $audioPlayer,
                        onLineTapped: self.playFrom, // タップ時の動作を渡す
                        playNextSegmentCallback: self.playNextSegment
                    )
                    
                    // 下部の再生バー (再生バーが存在する場合のみ表示)
                    if currentPlayingURL != nil || !transcriptLines.isEmpty {
                        CompactAudioPlayerView(
                            url: $currentPlayingURL,
                            player: $audioPlayer,
                            onPlaybackFinished: self.playNextSegment
                        )
                        .padding(.bottom, 8) // Safe Area を考慮したパディング (必要に応じて調整)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        HamburgerButton(showSidebar: $showSidebar)
                    }
                    ToolbarItem(placement: .principal) {
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

            if showSidebar && UIDevice.current.userInterfaceIdiom == .phone {
                Color.black.opacity(0.35)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false } } // アニメーション速度変更
                    .zIndex(0.5)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            if KeychainHelper.shared.apiKey() == nil {
                DispatchQueue.main.async { showSettings = true }
            }
            proxy.onSegment = { url, start in
                // バックグラウンド対応のハンドラを呼ぶ
                self.handleSegmentInBackground(url: url, start: start)
            }
            recorder.delegate = proxy

            // 通知センターの監視を追加
            NotificationCenter.default.publisher(for: .transcriptionDidFinish)
                .receive(on: DispatchQueue.main) // 必ずメインスレッドで受け取る
                .sink { notification in
                    self.handleTranscriptionResult(notification: notification)
                }
                .store(in: &cancellables) // 購読を管理
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
        currentPlayingURL = url
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // プレイヤー準備待ち
            guard self.audioPlayer?.url == url, !(self.audioPlayer?.isPlaying ?? false) else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                self.audioPlayer?.play()
            } catch { print("❌ Playback Error:", error.localizedDescription) }
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
        // fullAudioURL は現在の CompactAudioPlayerView が再生中のURL (または最後に再生したURL) を渡す
        // 履歴保存のタイミングと currentPlayingURL の整合性に注意
        historyManager.addHistoryItem(lines: transcriptLines, fullAudioURL: recorder.url) // recorder.url は AudioEngineRecorder が最後に書き出したファイルのURL (セグメントかもしれない)
                                                                                           // もしセッション全体の音声を別途保存しているなら、そのURLを渡す
    }

    private func cancelRecording() {
        Debug.log("❌ cancel tapped")
        isCancelling = true
        recorder.cancel()
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
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
            try? FileManager.default.removeItem(at: url) // キャンセル時は一時ファイルを削除
            return
        }
        print("🎧 Segment file path:", url.path)
        // currentPlayingURL は最初のセグメントで設定するか、再生ロジックで制御
        // if self.currentPlayingURL == nil { self.currentPlayingURL = url } 

        let newLine = TranscriptLine(id: UUID(), time: start, text: "…文字起こし中…", audioURL: url)
        self.transcriptLines.append(newLine)
        self.transcriptionTasks[url] = newLine.id // URLをキーにしてIDを保存

        // Task に @MainActor を追加してUI関連プロパティへのアクセスを安全にする
        Task { @MainActor in
            do {
                try client.transcribeInBackground(url: url, started: start)
                // 結果は NotificationCenter 経由で handleTranscriptionResult で処理される
            } catch {
                // 開始失敗時のエラー処理
                if let lineId = self.transcriptionTasks[url],
                   let index = self.transcriptLines.firstIndex(where: { $0.id == lineId }) {
                    self.transcriptLines[index].text = "⚠️ 開始エラー: \(error.localizedDescription)"
                    self.transcriptionTasks.removeValue(forKey: url) // エラー時もタスクリストから削除
                    try? FileManager.default.removeItem(at: url) // エラー時は一時ファイルを削除
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
            try? FileManager.default.removeItem(at: originalURL) // エラー時は一時ファイルを削除
        } else if let text = notification.userInfo?["text"] as? String {
            self.transcriptLines[index].text = text
            // 成功した場合、HistoryManager への保存は finishRecording で行うか、
            // ここでセグメントごとの音声ファイルを永続化するならその処理を行う。
            // 現在の実装では、HistoryManager はセッション終了時に呼ばれる。
            // 個別セグメントファイル (originalURL) は文字起こし後に不要なら削除できる。
            // HistoryItem が audioURL として実際のファイルパスを持つため、
            // HistoryManager.addHistoryItem の中でコピー処理を行っている。
            // ここで削除すると履歴から再生できなくなるため、削除タイミングは注意。
            // `transcriptionTasks` からの削除はここで行う。
        } else {
             self.transcriptLines[index].text = "⚠️ 不明なエラー"
            try? FileManager.default.removeItem(at: originalURL) // エラー時は一時ファイルを削除
        }
        self.transcriptionTasks.removeValue(forKey: originalURL)
    }

    // 次のセグメントを再生する
    private func playNextSegment() {
        guard let currentURL = currentPlayingURL else { return }
        guard let currentIndex = transcriptLines.firstIndex(where: { $0.audioURL == currentURL }) else {
            currentPlayingURL = nil // 見つからなければ再生終了
            return
        }

        let nextIndex = currentIndex + 1
        if transcriptLines.indices.contains(nextIndex),
           let nextURL = transcriptLines[nextIndex].audioURL {
            currentPlayingURL = nextURL // 次のセグメントをセット
            // playFrom を呼び出して再生開始
            DispatchQueue.main.async { // UI関連の更新なのでメインスレッドで
                 self.playFrom(url: nextURL)
            }
        } else {
            currentPlayingURL = nil // 次がなければ再生終了
        }
    }
    
    // 新規セッション準備
    private func prepareNewTranscriptionSession() {
        if !transcriptLines.isEmpty || currentPlayingURL != nil { // 何かあれば履歴に追加
             // recorder.url (AudioEngineRecorderが最後に保存したファイル) またはセッション全体の音声URL
            let sessionAudio = recorder.url // これは最後のセグメントの可能性あり。セッション全体のURLを管理する方が良い。
            historyManager.addHistoryItem(lines: transcriptLines, fullAudioURL: sessionAudio)
        }
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isCancelling = false // キャンセルフラグもリセット
    }

    // 履歴読み込み
    private func loadHistoryItem(_ historyItem: HistoryItem) {
        self.transcriptLines.removeAll()
        self.currentPlayingURL = nil
        self.audioPlayer?.stop()
        self.audioPlayer = nil

        self.transcriptLines = historyItem.getTranscriptLines(documentsDirectory: historyManager.documentsDirectory)

        if let fullAudio = historyItem.getFullAudioURL(documentsDirectory: historyManager.documentsDirectory) {
            self.currentPlayingURL = fullAudio
        } else if let firstSegment = self.transcriptLines.first?.audioURL { // セグメントの音声があれば最初のものを
            self.currentPlayingURL = firstSegment
        }
        
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
                    if activeMenuItem == .transcribe { // 既に選択されている場合は新規セッション準備
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
        formatter.dateFormat = "yyyy/M/d HH:mm:ss" // 履歴の日時フォーマット
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
        Button(action: { action() /* activeMenuItem = type は action 内で行うことが多い */ }) {
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
                    if isPlaying && !(player?.isPlaying ?? false) {
                       player?.play()
                    }
                } else if isPlaying {
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
        .onChange(of: url) { newURL in resetPlayer(url: newURL) } // onChange(of:perform:) の推奨される使い方
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
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                player.play()
                isPlaying = true
            } catch { print("❌ Playback Error:", error.localizedDescription) }
        }
    }
    
    private func updateProgress() {
        guard let player = player, !isEditingSlider else { return }

        currentTime = player.currentTime
        // duration は resetPlayer で設定されるので、ここでは不要な場合が多い
        // duration = player.duration 
        let wasPlaying = isPlaying
        isPlaying = player.isPlaying

        if player.isPlaying {
             progress = (duration > 0) ? (currentTime / duration) : 0
        }

        // 再生終了検知
        if wasPlaying && !player.isPlaying && duration > 0 && abs(currentTime - duration) < 0.1 { // 終了間際
            isPlaying = false
            progress = 1.0
            currentTime = duration // きっちり最後に合わせる
            DispatchQueue.main.async {
                self.onPlaybackFinished?()
            }
        }
    }
    
    private func resetPlayer(url: URL?) {
        player?.stop()
        isPlaying = false
        progress = 0.0
        currentTime = 0.0
        duration = 0.0 // duration もリセット
        isEditingSlider = false
        guard let urlToPlay = url else {
            self.player = nil
            return
        }
        do {
            self.player = try AVAudioPlayer(contentsOf: urlToPlay)
            self.player?.prepareToPlay()
            self.duration = self.player?.duration ?? 0.0 // ここでdurationを正しく設定
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
    @Binding var audioPlayerURL: URL?
    @Binding var audioPlayer: AVAudioPlayer?
    let onLineTapped: (URL) -> Void
    let playNextSegmentCallback: () -> Void

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