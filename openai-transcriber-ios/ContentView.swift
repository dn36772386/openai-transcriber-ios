import SwiftUI
import AVFoundation
import Foundation

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
    // --- ▼▼▼ 変更 ▼▼▼ ---
    @State private var currentPlayingURL: URL? // 再生中のURL
    // --- ▲▲▲ 変更 ▲▲▲ ---
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isCancelling = false // キャンセル操作中フラグ

    private let client = OpenAIClient()

    var body: some View {
        ZStack {
            NavigationView {
                MainContentView(
                    modeIsManual: $modeIsManual,
                    isRecording: $recorder.isRecording,
                    transcriptLines: $transcriptLines, 
                    audioPlayerURL: $currentPlayingURL, // 変更
                    audioPlayer: $audioPlayer
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        HamburgerButton(showSidebar: $showSidebar)
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Transcriber").font(.headline)
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
                    showSettings: $showSettings
                )
                .transition(.move(edge: .leading))
                .zIndex(1)
            }

            if showSidebar && UIDevice.current.userInterfaceIdiom == .phone {
                Color.black.opacity(0.35)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { withAnimation { showSidebar = false } }
                    .zIndex(0.5)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            if KeychainHelper.shared.apiKey() == nil {
                DispatchQueue.main.async { showSettings = true }
            }
            proxy.onSegment = { url, start in
                self.handleSegment(url: url, start: start)
            }
            recorder.delegate = proxy
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
    }

    private func cancelRecording() {
        Debug.log("❌ cancel tapped")
        isCancelling = true
        recorder.cancel()
        transcriptLines.removeAll()
        currentPlayingURL = nil // 変更
    }

    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { granted in
            handlePermissionResult(granted)
        }
    }

    // --- ▼▼▼ 修正箇所 ▼▼▼ ---
    private func handlePermissionResult(_ granted: Bool) {
        DispatchQueue.main.async {
            if granted {
                do { // do をここに配置
                    isCancelling = false
                    try recorder.start(isManual: self.modeIsManual)
                } catch { // catch をここに配置
                    print("[Recorder] start failed:", error.localizedDescription)
                } // catch の閉じ括弧
            } else {
                showPermissionAlert = true
            }
        }
    }
    // --- ▲▲▲ 修正箇所 ▲▲▲ ---

    @MainActor
    private func handleSegment(url: URL, start: Date) {
        guard !isCancelling else {
            Debug.log("🚫 Segment ignored due to cancel.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        print("🎧 Segment file path:", url.path)
        // --- ▼▼▼ 変更 ▼▼▼ ---
        // 最初のセグメントなら、それを再生対象にする
        if self.currentPlayingURL == nil { self.currentPlayingURL = url }
        // --- ▲▲▲ 変更 ▲▲▲ ---

        var currentLines = self.transcriptLines
        let idx = currentLines.count - 1 < 0 ? 0 : currentLines.count - 1

        if currentLines.isEmpty || currentLines[idx].text != "…文字起こし中…" {
             // --- ▼▼▼ 変更 ▼▼▼ ---
             currentLines.append(.init(time: start, text: "…文字起こし中…", audioURL: url)) // URLも保存
             // --- ▲▲▲ 変更 ▲▲▲ ---
        }
        let currentIndex = currentLines.count - 1
        self.transcriptLines = currentLines

        Task {
            let result: String
            do {
                result = try await client.transcribe(url: url)
            } catch {
                result = "⚠️ \(error.localizedDescription)"
            }

            await MainActor.run {
                guard !isCancelling else { return }
                var finalLines = self.transcriptLines
                if finalLines.indices.contains(currentIndex) {
                   // --- ▼▼▼ 変更 ▼▼▼ ---
                   finalLines[currentIndex].text = result
                   finalLines[currentIndex].audioURL = url // テキスト確定時にもURLを再確認
                   // --- ▲▲▲ 変更 ▲▲▲ ---
                   self.transcriptLines = finalLines
                }
            }
        }
    }
} // <-- ContentView の閉じ括弧

// ... (HamburgerButton, SidebarView, AudioPlayerView, MainContentView, #Preview は変更なし) ...
// (元のファイルにあるこれらの構造体をそのまま残してください)

// MARK: - Hamburger Button
struct HamburgerButton: View {
    @Binding var showSidebar: Bool
    var body: some View {
        Button(action: { withAnimation { showSidebar.toggle() } }) {
            Image(systemName: "line.horizontal.3")
                .imageScale(.large)
                .foregroundColor(Color.icon)
        }
    }
}

// MARK: - Sidebar
enum SidebarMenuItemType: CaseIterable {
    case transcribe, proofread, copy, audioDownload, settings
}

struct SidebarView: View {
    @Binding var showSidebar: Bool
    @Binding var activeMenuItem: SidebarMenuItemType?
    @Binding var showSettings: Bool // Receive binding

    struct HistoryItem: Identifiable {
        let id = UUID()
        let date: Date
    }
    @State private var historyItems: [HistoryItem] = [
        HistoryItem(date: Date().addingTimeInterval(-3600)),
        HistoryItem(date: Date().addingTimeInterval(-7200))
    ]
    @State private var selectedHistoryItem: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcriber")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 50) // Height adjustment

            VStack(alignment: .leading, spacing: 5) { // Spacing adjustment
                SidebarMenuItem(icon: "mic", text: "文字起こし", type: .transcribe, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "text.badge.checkmark", text: "校正", type: .proofread, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "doc.on.doc", text: "コピー", type: .copy, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "arrow.down.circle", text: "音声DL", type: .audioDownload, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "gearshape.fill", text: "設定", type: .settings, activeMenuItem: $activeMenuItem, action: {
                    showSettings = true // Show SettingsView
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
                    Button { historyItems.removeAll() } label: {
                        Image(systemName: "trash").foregroundColor(Color.icon)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 14).padding(.vertical, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(historyItems) { item in
                            HStack {
                                Text(item.date.toLocaleString())
                                    .font(.system(size: 13)).foregroundColor(Color.icon)
                                Spacer()
                                Button { historyItems.removeAll { $0.id == item.id } } label: {
                                    Image(systemName: "trash").foregroundColor(Color.icon)
                                        .opacity(selectedHistoryItem == item.id ? 1 : 0)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .background(selectedHistoryItem == item.id ? Color.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(4)
                            .onTapGesture { selectedHistoryItem = item.id }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(width: 240)
        .background(Color.sidebarBackground)
        // Removed border to match new design
        .edgesIgnoringSafeArea(UIDevice.current.userInterfaceIdiom == .phone ? .vertical : [])
    }

    private func closeSidebar() {
        if UIDevice.current.userInterfaceIdiom == .phone {
            withAnimation { showSidebar = false }
        }
    }
}

extension Date {
    func toLocaleString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm:ss" // Match image format
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
        Button(action: { activeMenuItem = type; action() }) {
            HStack(spacing: 12) { // Spacing adjustment
                Image(systemName: icon)
                    .font(.system(size: 16)) // Size adjustment
                    .frame(width: 20, alignment: .center)
                    .foregroundColor(isActive ? Color.accent : Color.icon)
                Text(text)
                    .font(.system(size: 14)) // Size adjustment
                    .foregroundColor(isActive ? Color.textPrimary : Color.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10) // Padding adjustment
            .background(isActive ? Color.accent.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .padding(.horizontal, 8).padding(.vertical, 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Audio Player
struct AudioPlayerView: View {
    @Binding var url: URL?
    @Binding var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var duration: TimeInterval = 0.0
    @State private var currentTime: TimeInterval = 0.0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    // --- ▼▼▼ 追加 ▼▼▼ ---
    // 連続再生のためのコールバック (次のステップで実装)
    // var onPlaybackFinished: (() -> Void)? 
    // --- ▲▲▲ 追加 ▲▲▲ ---

    var body: some View {
        HStack(spacing: 10) {
            Button { togglePlayPause() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
            Text(formatTime(currentTime) + " / " + formatTime(duration))
                .font(.caption)
                .foregroundColor(.textSecondary)
            Slider(value: $progress, in: 0...1, onEditingChanged: sliderChanged)
                .tint(Color.accent)
            Button { /* TODO: Volume */ } label: { Image(systemName: "speaker.wave.2.fill") }
            Button { /* TODO: More Options */ } label: { Image(systemName: "ellipsis") }
        }
        .font(.system(size: 18))
        .foregroundColor(Color.icon)
        .padding(.horizontal, 15).padding(.vertical, 12)
        .background(Color.cardBackground)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1)) // Add border
        .padding(.horizontal)
        .padding(.bottom, 10)
        .onReceive(timer) { _ in updateProgress() }
        // --- ▼▼▼ 変更 ▼▼▼ ---
        .onChange(of: url) { // iOS 17+
            resetPlayer(url: url)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func togglePlayPause() {
        guard let player = player else { return }
        if player.isPlaying { player.pause(); isPlaying = false }
        else {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                player.play(); isPlaying = true
            } catch { print("❌ Playback Error:", error.localizedDescription) }
        }
    }

    private func sliderChanged(editing: Bool) {
        guard let player = player, !editing else { return }
        player.currentTime = progress * player.duration
        currentTime = player.currentTime
    }

    private func updateProgress() {
        guard let player = player, player.isPlaying else { return }
        currentTime = player.currentTime
        duration = player.duration // Ensure duration is updated
        progress = duration > 0 ? currentTime / duration : 0
        if !player.isPlaying && duration > 0 && currentTime >= duration - 0.1 { // Check if finished
             isPlaying = false
             progress = 1.0
             currentTime = duration
             // onPlaybackFinished?() // 次のステップで有効化
        }
    }
    
    private func resetPlayer(url: URL?) {
        player?.stop(); isPlaying = false; progress = 0.0; currentTime = 0.0; duration = 0.0
        guard let urlToPlay = url else { self.player = nil; return }
        do {
            self.player = try AVAudioPlayer(contentsOf: urlToPlay)
            self.player?.prepareToPlay()
            self.duration = self.player?.duration ?? 0.0
        } catch { print("❌ Failed to load audio:", error.localizedDescription); self.player = nil }
    }
}

// MARK: - Main Content
struct MainContentView: View {
    @Binding var modeIsManual: Bool
    @Binding var isRecording: Bool
    @Binding var transcriptLines: [TranscriptLine]
    // --- ▼▼▼ 変更 ▼▼▼ ---
    @Binding var audioPlayerURL: URL?
    // --- ▲▲▲ 変更 ▲▲▲ ---
    @Binding var audioPlayer: AVAudioPlayer?

    var body: some View {
        VStack(spacing: 0) {
            // --- ▼▼▼ 変更 ▼▼▼ ---
            TranscriptView(lines: $transcriptLines) { tappedURL in
                // 行がタップされたらプレイヤーのURLを更新
                audioPlayerURL = tappedURL
            }
            // --- ▲▲▲ 変更 ▲▲▲ ---
                .padding(.top, 10)
                .padding(.horizontal, 10)

            // --- ▼▼▼ 変更 ▼▼▼ ---
            AudioPlayerView(url: $audioPlayerURL, player: $audioPlayer)
            // --- ▲▲▲ 変更 ▲▲▲ ---
        }
        .background(Color.appBackground.edgesIgnoringSafeArea(.all))
    }
}

// MARK: - Preview (Optional)
#Preview {
    ContentView()
}