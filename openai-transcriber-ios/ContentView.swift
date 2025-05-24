//
//  ContentView.swift
//  openai-transcriber-ios
//
//  Created by apple on 2025/05/13.
//

import SwiftUI
import AVFoundation
import Foundation

// CSSカラーパレットの定義
extension Color {
    static let appBackground = Color(hex: "#F9FAFB") // Slightly lighter grey
    static let sidebarBackground = Color(hex: "#ffffff")
    static let accent = Color(hex: "#10B981") // Teal/Green accent
    static let icon = Color(hex: "#374151")   // Darker grey icon
    // static let hover = Color(hex: "#111827") // Hover is handled differently
    static let border = Color(hex: "#e5e7eb")
    static let danger = Color(hex: "#dc2626")
    static let cardBackground = Color(hex: "#ffffff")
    static let textPrimary = Color(hex: "#1F2937") // Darker text
    static let textSecondary = Color(hex: "#6b7280")
}

// 16進数カラーコードからColorを生成するイニシャライザ
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}


struct ContentView: View {
    @State private var proxy = RecorderProxy()           // ← 追加
    @StateObject private var recorder = AudioEngineRecorder()
    @State private var showPermissionAlert = false
    @State private var showSidebar = UIDevice.current.userInterfaceIdiom != .phone // iPadなら最初から表示
    @State private var showApiKeyModal = false
    @State private var modeIsManual = false
    @State private var activeMenuItem: SidebarMenuItemType? = .transcribe // 初期選択
    @State private var permissionChecked = false    // デバッグ用
    @State private var showSettings = false        // ← モーダル制御
    @State private var transcriptLines: [TranscriptLine] = [] // 文字起こし結果
    @State private var lastSegmentURL: URL? // 最後に録音されたファイルのURL (再生用)
    @State private var audioPlayer: AVAudioPlayer? // 再生用プレイヤー

    /// OpenAI 文字起こしクライアント（ビューが生きている間に 1 度だけ生成）
    private let client = OpenAIClient()

    var body: some View {
        ZStack {
            NavigationView {
                MainContentView(
                    modeIsManual: $modeIsManual,
                    showApiKeyModal: $showApiKeyModal,
                    isRecording: $recorder.isRecording,
                    transcriptLines: $transcriptLines,
                    lastSegmentURL: $lastSegmentURL, // ◀︎◀︎ 渡す
                    audioPlayer: $audioPlayer        // ◀︎◀︎ 渡す
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
                            Toggle("", isOn: $modeIsManual)
                                .labelsHidden()
                                .tint(Color.accent)
                            Text(modeIsManual ? "manual" : "auto")
                                .font(.caption)
                                .foregroundColor(Color.textSecondary)

                            Button {
                                toggleRecording() // 録音開始/停止
                            } label: {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(recorder.isRecording ? Color.danger : Color.accent)
                            }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .background(Color.appBackground.edgesIgnoringSafeArea(.all))
            }
            .navigationViewStyle(StackNavigationViewStyle()) // iPadでの挙動を調整

            // Sidebar
            if showSidebar {
                SidebarView(
                    showSidebar: $showSidebar,
                    showApiKeyModal: $showApiKeyModal,
                    activeMenuItem: $activeMenuItem
                )
                .transition(.move(edge: .leading))
                .zIndex(1) // Sidebarを前面に
            }

            // Backdrop for phone
            if showSidebar && UIDevice.current.userInterfaceIdiom == .phone {
                Color.black.opacity(0.35)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        withAnimation {
                            showSidebar = false
                        }
                    }
                    .zIndex(0.5) // Sidebarより後ろ、MainContentより前
            }
        }
        .sheet(isPresented: $showApiKeyModal) {
            ApiKeyModalView(showApiKeyModal: $showApiKeyModal)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            if KeychainHelper.shared.apiKey() == nil {          // 未設定なら即表示
                DispatchQueue.main.async { showSettings = true }
            }
        }
        .alert("マイクへのアクセスが許可されていません",
               isPresented: $showPermissionAlert) {
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

    // MARK: - Private

    private func toggleRecording() {
        if recorder.isRecording {
            Debug.log("🔴 stop tapped")
            recorder.stop()
        } else {
            requestMicrophonePermission()   // 開始前に権限確認
        }
    }

    private func requestMicrophonePermission() {
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                handlePermissionResult(granted)
            })
        } else {
            AVAudioSession.sharedInstance()
                .requestRecordPermission { granted in
                    handlePermissionResult(granted)
                }
        }
    }

    private func handlePermissionResult(_ granted: Bool) {
        DispatchQueue.main.async {
            if granted {
                do {
                    proxy.onSegment = handleSegment(url:start:)   // クロージャ設定
                    recorder.delegate = proxy                     // delegate 差替え
                    try recorder.start()          // 録音開始
                } catch {
                    print("[Recorder] start failed:", error.localizedDescription)
                }
            } else {
                showPermissionAlert = true
            }
        }
    }

    // MARK: - segment 受信ハンドラ
    @MainActor
    private func handleSegment(url: URL, start: Date) {
        transcriptLines.append(.init(time: start, text: "…文字起こし中…"))
        self.lastSegmentURL = url // URLを保存
        let idx = transcriptLines.count - 1

        // 非同期処理はバックグラウンドで走らせつつ、
        // UI 更新は必ず MainActor 上で行う
        Task {
            let result: String
            do {
                // 生成しておいたインスタンス `client` を使う
                result = try await client.transcribe(url: url)
            } catch {
                result = "⚠️ \(error.localizedDescription)"
            }

            await MainActor.run {
                // in-place ではなく、コピーして置き換える
                var lines = transcriptLines
                if lines.indices.contains(idx) {
                    lines[idx].text = result
                    transcriptLines = lines
                }
            }
        }
    }
}

struct HamburgerButton: View {
    @Binding var showSidebar: Bool

    var body: some View {
        Button(action: {
            withAnimation {
                showSidebar.toggle()
            }
        }) {
            Image(systemName: "line.horizontal.3")
                .imageScale(.large)
                .foregroundColor(Color.icon)
        }
    }
}

enum SidebarMenuItemType: CaseIterable {
    case transcribe, proofread, copy, audioDownload, settings
}

struct SidebarView: View {
    @Binding var showSidebar: Bool
    @Binding var showApiKeyModal: Bool
    @Binding var activeMenuItem: SidebarMenuItemType?

    // 履歴アイテムのプレースホルダー
    struct HistoryItem: Identifiable {
        let id = UUID()
        let date: Date
    }
    @State private var historyItems: [HistoryItem] = [
        HistoryItem(date: Date().addingTimeInterval(-3600)),
        HistoryItem(date: Date().addingTimeInterval(-7200))
    ]
    @State private var selectedHistoryItem: UUID?
    @State private var showSettings = false // 設定モーダル用

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (ロゴ表示エリア)
            Text("Transcriber")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 44) // CSSの #sidebar header の高さに合わせる

            // Menu items
            VStack(alignment: .leading, spacing: 0) {
                SidebarMenuItem(icon: "mic", text: "文字起こし", type: .transcribe, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "text.badge.checkmark", text: "校正", type: .proofread, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "doc.on.doc", text: "コピー", type: .copy, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "arrow.down.circle", text: "音声DL", type: .audioDownload, activeMenuItem: $activeMenuItem, action: { closeSidebar() })
                SidebarMenuItem(icon: "gearshape.fill", text: "設定", type: .settings, activeMenuItem: $activeMenuItem, action: {
                    showSettings = true // 設定モーダルを表示
                    closeSidebar()
                })
            }

            // History Section
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("履歴")
                        .font(.system(size: 14))
                        .foregroundColor(Color.textSecondary)
                    Spacer()
                    Button(action: {
                        // TODO: Clear all history
                        historyItems.removeAll()
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(Color.icon)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .border(width: 1, edges: [.top], color: Color.border)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(historyItems) { item in
                            HStack {
                                Text(item.date.toLocaleString()) // より詳細なフォーマットが必要
                                    .font(.system(size: 13))
                                    .foregroundColor(Color.icon)
                                
                                Spacer()
                                Button(action: {
                                    // TODO: Delete specific history item
                                    historyItems.removeAll(where: { $0.id == item.id })
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(Color.icon)
                                        .opacity(selectedHistoryItem == item.id ? 1 : 0) // ホバーのような効果
                                }
                                .buttonStyle(PlainButtonStyle()) // ボタンのデフォルトスタイルを解除
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(selectedHistoryItem == item.id ? Color.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(4) // 少し角を丸める
                            .onTapGesture {
                                selectedHistoryItem = item.id
                                // TODO: Load history item
                            }
                            .padding(.horizontal, 6) // List内の左右パディング
                            .padding(.vertical, 2)   // List内の上下パディング
                        }
                    }
                }
            }
            .padding(.top, 8)


            Spacer() // Pushes content to top
        }
        .frame(width: 240)
        .background(Color.sidebarBackground)
        .border(width: 1, edges: [.trailing], color: Color.border)
        .edgesIgnoringSafeArea(UIDevice.current.userInterfaceIdiom == .phone ? .vertical : []) // iPhoneでは上下無視
        .sheet(isPresented: $showSettings) { // 設定モーダル表示
            SettingsView()
        }
    }

    private func closeSidebar() {
        if UIDevice.current.userInterfaceIdiom == .phone {
            withAnimation {
                showSidebar = false
            }
        }
    }
}

// Date extension for toLocaleString (simplified)
extension Date {
    func toLocaleString() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: self)
    }
}


struct SidebarMenuItem: View {
    let icon: String
    let text: String
    let type: SidebarMenuItemType
    @Binding var activeMenuItem: SidebarMenuItemType?
    let action: () -> Void

    var isActive: Bool {
        activeMenuItem == type
    }

    var body: some View {
        Button(action: {
            activeMenuItem = type
            action()
        }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18)) // アイコンサイズ調整
                    .frame(width: 24, alignment: .center)
                    .foregroundColor(isActive ? Color.accent : Color.icon)
                Text(text) // 文字サイズ調整
                    .font(.system(size: 15)) // 文字サイズ調整
                    .foregroundColor(isActive ? Color.textPrimary : Color.textSecondary) // 色変更
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12) // パディング調整
            .background(isActive ? Color.accent.opacity(0.1) : Color.clear) // アクティブ時の背景
            .cornerRadius(6) // 角を丸める
            .padding(.horizontal, 8) // 左右にマージン
            .padding(.vertical, 2)   // 上下にマージン
        }
        .buttonStyle(PlainButtonStyle()) // ボタンのデフォルトスタイルを解除
    }
}

// 古いヘッダーコントロールは削除 - コメントアウト
/*
struct HeaderRecordingControls: View {
    @Binding var isRecording: Bool
    @Binding var modeIsManual: Bool
    var startAction: () -> Void
    var stopAndSendAction: () -> Void
    var cancelAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(modeIsManual ? "manual" : "auto")
                    .font(.system(size: 12)) // modeLabel
                    .foregroundColor(Color.textPrimary)
                Toggle("", isOn: $modeIsManual)
                    .labelsHidden()
                    .scaleEffect(0.8) // トグルを少し小さく
                    .tint(Color.accent)
            }

            if !isRecording {
                // ▶︎ 録音開始
                Button(action: { startAction() }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color.accent)
                }
            } else {
                // ■ 録音停止
                Button(action: { stopAndSendAction() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color.red)
                }
            }

            // キャンセルボタン (常に表示)
            Button(action: { cancelAction() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color.icon)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.cardBackground)
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}
*/

struct AudioPlayerView: View {
    @Binding var url: URL?
    @Binding var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var duration: TimeInterval = 0.0
    @State private var currentTime: TimeInterval = 0.0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Button { togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            Text(formatTime(currentTime))
            Slider(value: $progress, in: 0...1, onEditingChanged: sliderChanged)
                .tint(Color.accent)
            Text(formatTime(duration))
            Button { /* TODO: Volume */ } label: {
                Image(systemName: "speaker.wave.2.fill")
            }
            Button { /* TODO: More Options */ } label: {
                Image(systemName: "ellipsis")
            }
        }
        .font(.system(size: 16))
        .foregroundColor(Color.icon)
        .padding(15)
        .background(Color.cardBackground)
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: -2) // 上向きの影を少し
        .padding(.horizontal)
        .padding(.bottom, 10)
        .onReceive(timer) { _ in updateProgress() }
        .onChange(of: url) { newUrl in resetPlayer(url: newUrl) }
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
            // 再生セッション設定
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                player.play()
                isPlaying = true
            } catch {
                print("❌ Playback Error:", error.localizedDescription)
            }
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
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
        if !player.isPlaying {
            isPlaying = false
            currentTime = player.duration // 終わったら最後に
            progress = 1.0
        }
    }
    
    private func resetPlayer(url: URL?) {
        player?.stop()
        isPlaying = false
        progress = 0.0
        currentTime = 0.0
        duration = 0.0
        guard let urlToPlay = url else {
            self.player = nil
            return
        }
        do {
            self.player = try AVAudioPlayer(contentsOf: urlToPlay)
            self.player?.prepareToPlay()
            self.duration = self.player?.duration ?? 0.0
        } catch {
            print("❌ Failed to load audio for player:", error.localizedDescription)
            self.player = nil
        }
    }
}

struct MainContentView: View {
    @Binding var modeIsManual: Bool
    @Binding var showApiKeyModal: Bool
    @Binding var isRecording: Bool
    @Binding var transcriptLines: [TranscriptLine]
    @Binding var lastSegmentURL: URL? // ◀︎◀︎ 追加
    @Binding var audioPlayer: AVAudioPlayer? // ◀︎◀︎ 追加

    var body: some View {
        VStack(spacing: 0) {
            // Content Area
            VStack(spacing: 15) { // 間隔を調整
                ZStack(alignment: .topLeading) {
                    TranscriptView(lines: $transcriptLines)
                }
                .frame(maxHeight: .infinity)
                .padding(.top) // 上部に少しパディング

                // New Audio Player
                AudioPlayerView(url: $lastSegmentURL, player: $audioPlayer)
            }
            .padding(.horizontal, 10) // 左右のパディングを少し減らす
        }
        .background(Color.appBackground.edgesIgnoringSafeArea(.all))
    }

struct ApiKeyModalView: View {
    @Binding var showApiKeyModal: Bool
    @State private var apiKey: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                Text("OpenAI APIキー")
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.bottom, 6)
                TextField("sk-...", text: $apiKey)
                    .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6))
                    .background(Color.white)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.border, lineWidth: 1)
                    )
                Button("保存") {
                    // TODO: Save API Key logic
                    showApiKeyModal = false
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accent)
                .foregroundColor(.white)
                .cornerRadius(4)
                .padding(.top, 10)
                Spacer()
            }
            .padding(16)
            .frame(width: 260)
            .background(Color.white)
            .cornerRadius(6)
            .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 4)
            .navigationBarItems(trailing: Button("閉じる") {
                showApiKeyModal = false
            })
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("APIキー設定")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3).edgesIgnoringSafeArea(.all))
    }
}

// EdgeBorder extension for applying border to specific edges
struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat {
                switch edge {
                case .top, .bottom, .leading: return rect.minX
                case .trailing: return rect.maxX - width
                }
            }

            var y: CGFloat {
                switch edge {
                case .top, .leading, .trailing: return rect.minY
                case .bottom: return rect.maxY - width
                }
            }

            var w: CGFloat {
                switch edge {
                case .top, .bottom: return rect.width
                case .leading, .trailing: return self.width
                }
            }

            var h: CGFloat {
                switch edge {
                case .top, .bottom: return self.width
                case .leading, .trailing: return rect.height
                }
            }
            path.addPath(Path(CGRect(x: x, y: y, width: w, height: h)))
        }
        return path
    }
}

extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(EdgeBorder(width: width, edges: edges).foregroundColor(color))
    }
}

#Preview {
    ContentView()
}
