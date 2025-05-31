import SwiftUI
import AVFoundation
import Foundation
import Combine
import UniformTypeIdentifiers
import UIKit

// MARK: - Color Palette
extension Color {
    static let appBackground = Color(hex: "#F9FAFB")
    static let sidebarBackground = Color(hex: "#ffffff")
    static let accent = Color(hex: "#6b7280")
    static let icon = Color(hex: "#374151")
    static let border = Color(hex: "#e5e7eb")
    static let danger = Color(hex: "#6b7280")
    static let cardBackground = Color(hex: "#ffffff")
    static let textPrimary = Color(hex: "#1F2937")
    static let textSecondary = Color(hex: "#6b7280")
    static let playerBackground = Color(hex: "#1F2937")
    static let playerText = Color(hex: "#ffffff")
    static let iconOutline = Color(hex: "#374151").opacity(0.8)

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
    static let transcriptionDidFinish = Notification.Name("transcriptionDidFinishNotification")
}

// MARK: - Content Tab
enum ContentTab {
    case transcription
    case summary
}

// MARK: - Sidebar Enum
enum SidebarMenuItemType: CaseIterable {
    case transcribe, shortMemo, importAudio, copy, settings
}

// MARK: - Content View Wrapper (iOS 15+ Compatibility)
@available(iOS 15.0, *)
struct ContentViewWrapper: View {
    var body: some View {
        if #available(iOS 16.0, *) {
            ContentView()
        } else {
            Text("iOS 16以降が必要です")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Main View
@available(iOS 16.0, *)
struct ContentView: View {
    @State private var proxy = RecorderProxy()
    @StateObject private var recorder = AudioEngineRecorder()
    @StateObject private var audioPlayerDelegate = AudioPlayerDelegateWrapper()
    @State private var showPermissionAlert = false
    @State private var showSidebar = UIDevice.current.userInterfaceIdiom != .phone
    @State private var activeMenuItem: SidebarMenuItemType? = .transcribe
    @State private var showSettings = false
    @State private var showShortMemo = false
    @State private var transcriptLines: [TranscriptLine] = []
    @State private var currentPlayingURL: URL?
    @State private var audioPlayer: AVAudioPlayer?
    @StateObject private var historyManager = HistoryManager.shared
    @State private var isCancelling = false
    @State private var transcriptionTasks: [URL: UUID] = [:]
    @State private var cancellables = Set<AnyCancellable>()
    @State private var showFilePicker = false
    @StateObject private var fileProcessor = AudioFileProcessor()
    @State private var showProcessingProgress = false
    @State private var showFormatAlert = false
    @State private var formatAlertMessage = ""
    @State private var selectedTab: ContentTab = .transcription
    @State private var currentSummary: String? = nil
    @State private var currentSubtitle: String? = nil
    @State private var isEditingSubtitle = false
    @State private var editingSubtitleText = ""
    @State private var isGeneratingSummary = false
    @State private var showSummaryOptions = false
    @State private var selectedSummaryLevel: SummaryLevel = .standard
    
    
    // タイトルタップ用の状態
    @State private var showTitleMenu = false
    @State private var titleText = "Transcriber"
    @State private var isTitlePressed = false
    
    private let client = OpenAIClient()
    
    var body: some View {
        ZStack(alignment: .leading) {
            NavigationView {
                VStack(spacing: 0) {
                    // メインコンテンツ
                    // タブビューを追加
                    ContentTabView(selectedTab: $selectedTab)
                        .background(Color.white)
                        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                        .padding(.bottom, 0)
                    
                    // 既存のMainContentViewをswitch文で囲む
                    TabView(selection: $selectedTab) {
                    switch selectedTab {
                    case .transcription:
                        MainContentView(
                            isRecording: $recorder.isRecording,
                            transcriptLines: $transcriptLines,
                            audioPlayerURL: $currentPlayingURL,
                            audioPlayer: $audioPlayer,
                            onLineTapped: self.playFrom,
                            onRetranscribe: { line in
                                if let index = self.transcriptLines.firstIndex(where: { $0.id == line.id }),
                                   let audioURL = line.audioURL {
                                    self.transcriptLines[index].text = "…再文字起こし中…"
                                    self.transcriptionTasks[audioURL] = line.id
                                    Task { @MainActor in
                                        do {
                                            try self.client.transcribeInBackground(url: audioURL, started: line.time)
                                        } catch {
                                            self.transcriptLines[index].text = "⚠️ 再文字起こしエラー: \(error.localizedDescription)"
                                            self.transcriptionTasks.removeValue(forKey: audioURL)
                                        }
                                    }
                                }
                            },
                            playNextSegmentCallback: self.playNextSegment
                        )
                        .tag(ContentTab.transcription)
                        .gesture(DragGesture()
                            .onEnded { value in
                                if value.translation.width < -50 {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedTab = .summary
                                    }
                                }
                            }
                        )
                    case .summary:
                        SummaryView(
                            transcriptLines: $transcriptLines,
                            currentSummary: $currentSummary,
                            currentSubtitle: $currentSubtitle,
                            onSummaryGenerated: { summary, subtitle in 
                                self.currentSummary = summary
                                self.currentSubtitle = subtitle
                            },
                            isGeneratingSummary: $isGeneratingSummary,
                            showSummaryOptions: $showSummaryOptions,
                            selectedSummaryLevel: $selectedSummaryLevel
                        )
                        .tag(ContentTab.summary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                        .gesture(DragGesture()
                            .onEnded { value in
                                if value.translation.width > 50 {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedTab = .transcription
                                    }
                                }
                            }
                        )
                    }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                     
                    // 下部のコントロール（再生バーまたは要約生成ボタン）
                    if !transcriptLines.isEmpty {
                        if selectedTab == .transcription {
                            // 文字起こしタブ：再生バー
                            CompactAudioPlayerView(
                                url: $currentPlayingURL,
                                player: $audioPlayer,
                                onPlaybackFinished: self.playNextSegment,
                                playerDelegate: audioPlayerDelegate
                            )
                            .padding(.bottom, 16)
                        } else {
                            // 要約タブ：要約生成ボタン
                            Button(action: { 
                                showSummaryOptions = true 
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 14, weight: .regular))
                                    Text(isGeneratingSummary ? "生成中..." : "要約を生成")
                                        .font(.system(size: 14, weight: .regular))
                                }
                                .foregroundColor(isGeneratingSummary ? Color.textSecondary : Color.textPrimary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.border, lineWidth: 1)
                                )
                            }
                            .disabled(isGeneratingSummary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
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
                            if recorder.isRecording {
                                Button {
                                    finishRecording()
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundColor(Color.accent)
                                }
                                Button {
                                    cancelRecording()
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundColor(Color.danger)
                                }
                            } else {
                                Button {
                                    startRecording()
                                } label: {
                                    Image(systemName: "mic.circle")
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundColor(Color.accent)
                                }
                            }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                isTitlePressed = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isTitlePressed = false
                            }
                            if !transcriptLines.isEmpty {
                                showTitleMenu = true
                                // より軽い振動に変更
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                            }
                        }) {
                            HStack(spacing: 4) {
                                VStack(spacing: 2) {
                                    Text(titleText)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    if !transcriptLines.isEmpty, let subtitle = currentSubtitle {
                                        Text(subtitle)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                
                                // タップ可能なことを示すアイコン
                                if !transcriptLines.isEmpty {
                                    Image(systemName: isTitlePressed ? "chevron.down.circle.fill" : "chevron.down.circle")
                                        .font(.system(size: 16))
                                        .foregroundColor(isTitlePressed ? .accentColor : .secondary.opacity(0.6))
                                        .scaleEffect(isTitlePressed ? 0.9 : 1.0)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isTitlePressed ? Color.gray.opacity(0.1) : Color.clear)
                            .cornerRadius(8)
                        }
                        .disabled(transcriptLines.isEmpty)
                        .opacity(transcriptLines.isEmpty ? 0.5 : 1.0)
                    }
                }
                .background(Color.appBackground.edgesIgnoringSafeArea(.all))
                
                // タイトルメニュー
                .confirmationDialog("共有", isPresented: $showTitleMenu) {
                    Button("文字起こし全文") { shareFullText() }
                    if currentSummary != nil {
                        Button("要約") { shareSummary() }
                    }
                    if currentSubtitle != nil {
                        Button("サブタイトル") { shareSubtitle() }
                    }
                    Button("キャンセル", role: .cancel) {}
                }
                
                // サブタイトル編集エリア（非表示に）
            }
            .navigationViewStyle(StackNavigationViewStyle())

            // Sidebar
            if showSidebar {
                SidebarView(
                    showSidebar: $showSidebar,
                    activeMenuItem: $activeMenuItem,
                    showSettings: $showSettings,
                    showShortMemo: $showShortMemo,
                    onLoadHistoryItem: self.loadHistoryItem,
                    onPrepareNewSession: { self.prepareNewSessionInternal(saveCurrentSession: true) },
                    onImportAudio: {
                        // 音声インポートは新規セッションとして扱う
                        self.prepareNewSessionInternal(saveCurrentSession: true)
                        self.showFilePicker = true
                    }
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
        .sheet(isPresented: $showShortMemo) { ShortMemoView() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: AudioFormatHandler.supportedFormats,
            allowsMultipleSelection: false
        ) { result in
            Debug.log("📄 --- fileImporter 開始 ---") // ログ追加
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Debug.log("📄 fileImporter 成功. URL: \(url.path), securityScoped: \(url.startAccessingSecurityScopedResource())") // ログ追加 (セキュリティスコープ開始も試す)
                    url.stopAccessingSecurityScopedResource() // すぐに停止してみる（テスト）
                    processImportedFileWithFormatSupport(url)
                } else {
                    Debug.log("📄 fileImporter 成功 (URLなし)") // ログ追加
                }
            case .failure(let error):
                Debug.log("📄 fileImporter 失敗: \(error.localizedDescription)") // ログ追加
                formatAlertMessage = "ファイル選択エラー: \(error.localizedDescription)"
                showFormatAlert = true
            }
            Debug.log("📄 --- fileImporter 終了 ---") // ログ追加
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
            .allowsHitTesting(false)
            .disabled(true)
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
            
            proxy.onSegment = { url, start in
                self.handleSegmentInBackground(url: url, start: start)
            }
            recorder.delegate = proxy
            
            audioPlayerDelegate.onPlaybackFinished = {
                playNextSegment()
            }
            
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
        .onChange(of: transcriptLines) { _, _ in
            updateTitleText()
        }
        .onChange(of: currentSubtitle) { _, _ in
            updateTitleText()
        }
        .onChange(of: selectedTab) { _, _ in
            // タブ切り替え時の振動
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
        }
    }

    // MARK: - Recording Methods
    
    private func startRecording() {
        guard !recorder.isRecording else { return }
        
        // 要約生成中かチェック
        if isGeneratingSummary {
            // 要約生成中は録音開始を制限
            Debug.log("⚠️ 要約生成中のため録音開始を制限")
            return
        }
        
        requestMicrophonePermission()
    }

    private func finishRecording() {
        Debug.log("✅ finish tapped")
        isCancelling = false
        recorder.stop()
        saveOrUpdateCurrentSession()
    }

    private func cancelRecording() {
        Debug.log("❌ cancel tapped")
        isCancelling = true
        recorder.cancel()
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        transcriptionTasks.removeAll()
        currentSummary = nil
        currentSubtitle = nil
        if let currentId = historyManager.currentHistoryId {
            historyManager.deleteHistoryItem(id: currentId)
        }
        historyManager.currentHistoryId = nil
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
                    transcriptLines.removeAll()
                    currentPlayingURL = nil
                    audioPlayer?.stop()
                    audioPlayer = nil
                    currentSummary = nil
                    currentSubtitle = nil
                    transcriptionTasks.removeAll()
                    
                    // 録音開始時に履歴を作成
                    historyManager.currentHistoryId = historyManager.startNewSession()
                    
                    print("Starting recorder")
                    try recorder.start(isManual: false)  // 常に自動モードで開始
                } catch {
                    print("[Recorder] start failed:", error.localizedDescription)
                }
            } else {
                showPermissionAlert = true
            }
        }
    }

    // MARK: - File Import Methods
    
    private func processImportedFileWithFormatSupport(_ url: URL) {
        Debug.log("⚙️ --- processImportedFileWithFormatSupport 開始: \(url.lastPathComponent) ---") // ログ追加
        
        // 音声インポートは必ず新規セッションとして扱う（prepareNewSessionInternalで既に処理済み）
        // 現在の履歴IDがない場合のみ新規作成
        if historyManager.currentHistoryId == nil {
            historyManager.currentHistoryId = historyManager.startNewSession()
        }

        Debug.log("⚙️ セキュリティスコープアクセス開始試行") // ログ追加
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        Debug.log("⚙️ セキュリティスコープアクセス開始結果: \(shouldStopAccessing)") // ログ追加

        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
                Debug.log("⚙️ セキュリティスコープアクセス停止 (defer)") // ログ追加
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent(url.lastPathComponent)
        Debug.log("⚙️ コピー先Local URL: \(localURL.path)") // ログ追加

        do {
            Debug.log("⚙️ ファイルコピー開始") // ログ追加
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
                Debug.log("⚙️ 既存ファイルを削除") // ログ追加
            }
            try FileManager.default.copyItem(at: url, to: localURL)
            Debug.log("⚙️ ファイルコピー成功") // ログ追加
        } catch {
            Debug.log("❌ ファイルコピー失敗: \(error.localizedDescription)") // ログ追加
            Task { @MainActor in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showFormatError("ファイルのコピーに失敗しました: \(error.localizedDescription)")
                }
            }
            return
        }

        Debug.log("⚙️ Task開始") // ログ追加
        Task {
            Debug.log("⚙️ Task内: validateFormat 呼び出し開始") // ログ追加
            let validation = await AudioFormatHandler.validateFormat(url: localURL)
            Debug.log("⚙️ Task内: validateFormat 終了. isValid: \(validation.isValid)") // ログ追加

            guard validation.isValid else {
                Debug.log("❌ Task内: フォーマット無効. Error: \(validation.error ?? "N/A")") // ログ追加
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showFormatError(validation.error ?? "不明なエラー")
                    }
                }
                try? FileManager.default.removeItem(at: localURL)
                return
            }
            
            Debug.log("⚙️ Task内: メタデータ取得試行") // ログ追加
            if let metadata = await AudioFormatHandler.getAudioMetadata(from: url) {
                Debug.log("📊 Audio Metadata: \(metadata.formattedDuration)") // ログ追加
            }

            await MainActor.run {
                Debug.log("⚙️ Task内: プログレス表示") // ログ追加
                showProcessingProgress = true
            }

            do {
                Debug.log("⚙️ Task内: extractAudio/performSilenceSplitting 呼び出し開始") // ログ追加
                let processedURL = try await AudioFormatHandler.extractAudio(from: localURL)
                await performSilenceSplitting(processedURL, originalURL: localURL)
                Debug.log("⚙️ Task内: extractAudio/performSilenceSplitting 終了") // ログ追加
            } catch {
                Debug.log("❌ Task内: extractAudio/performSilenceSplitting 失敗: \(error.localizedDescription)") // ログ追加
                await MainActor.run {
                    self.showProcessingProgress = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.showFormatError(error.localizedDescription)
                    }
                }
                try? FileManager.default.removeItem(at: localURL)
            }
            Debug.log("⚙️ --- Task 終了 ---") // ログ追加
        }
        Debug.log("⚙️ --- processImportedFileWithFormatSupport 終了 ---") // ログ追加
    }
    
    @MainActor // ◀︎◀︎ @MainActor を追加
    private func performSilenceSplitting(_ url: URL, originalURL: URL) async {
        do {
            Debug.log("🎵 Processing file: \(url.lastPathComponent)")
            Debug.log("🎵 Original file: \(originalURL.lastPathComponent)")
            
            let result = try await fileProcessor.processFile(at: url)
            let originalFileName = originalURL.lastPathComponent
            
            Debug.log("✅ Processing completed: \(result.segments.count) segments found")
            
            for (index, segment) in result.segments.enumerated() {
                let startDate = Date(timeIntervalSinceNow: -result.totalDuration + segment.startTime)
                
                // 🔽 MainActor.run を削除 (関数全体が @MainActor のため)
                if index == 0 {
                    self.currentPlayingURL = segment.url
                }
                
                let newLine = TranscriptLine(
                    id: UUID(),
                    time: startDate,
                    text: "…文字起こし中… [\(originalFileName) - セグメント\(index + 1)]",
                    audioURL: segment.url
                )
                self.transcriptLines.append(newLine)
                self.transcriptionTasks[segment.url] = newLine.id // ✅ OK
                
                try client.transcribeInBackground(
                    url: segment.url,
                    started: startDate
                )
            }
            
            showProcessingProgress = false // ◀︎◀︎ MainActor.run を削除
            
            if url != originalURL {
                try? FileManager.default.removeItem(at: url)
            }
            
        } catch {
            Debug.log("❌ performSilenceSplitting error: \(error)")
            Debug.log("❌ Error type: \(type(of: error))")
            Debug.log("❌ Error description: \(error.localizedDescription)")
            
            showProcessingProgress = false // ◀︎◀︎ MainActor.run を削除
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showFormatError("処理エラー: \(error.localizedDescription)")
            }
        }
    }
    
    private func showFormatError(_ message: String) {
        formatAlertMessage = message
        showFormatAlert = true
    }

    // MARK: - Segment & Transcription Methods
    
    @MainActor
    private func handleSegmentInBackground(url: URL, start: Date) {
        guard !isCancelling else {
            Debug.log("🚫 Segment ignored due to cancel.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        print("🎧 Segment file path:", url.path)

        // 履歴は録音開始時に既に作成されているはず

        if self.currentPlayingURL == nil { self.currentPlayingURL = url }

        let newLine = TranscriptLine(id: UUID(), time: start, text: "…文字起こし中…", audioURL: url)
        self.transcriptLines.append(newLine)
        self.transcriptionTasks[url] = newLine.id

        Task { @MainActor in
            do {
                try client.transcribeInBackground(url: url, started: start)
            } catch {
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
        } else if let text = notification.userInfo?["text"] as? String {
            self.transcriptLines[index].text = text
        } else {
            self.transcriptLines[index].text = "⚠️ 不明なエラー"
        }
        self.transcriptionTasks.removeValue(forKey: originalURL)
    }

    // MARK: - Audio Playback Methods
    
    private func playNextSegment() {
        Debug.log("🎵 playNextSegment called")
        
        guard let currentURL = currentPlayingURL else {
            Debug.log("❌ No current playing URL")
            return
        }
        
        guard let currentIndex = transcriptLines.firstIndex(where: { $0.audioURL == currentURL }) else {
            Debug.log("❌ Current URL not found in transcript lines")
            currentPlayingURL = nil
            return
        }
        
        let nextIndex = currentIndex + 1
        if transcriptLines.indices.contains(nextIndex) {
            if let nextURL = transcriptLines[nextIndex].audioURL {
                Debug.log("✅ Playing next segment: \(nextURL.lastPathComponent)")
                playFrom(url: nextURL)
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
    
    private func playFrom(url: URL) {
        print("🛠 🎵 playFrom called with URL: \(url.lastPathComponent)")
        
        // 空のURLの場合は停止処理
        if url.path.isEmpty {
            audioPlayer?.stop()
            audioPlayer = nil
            currentPlayingURL = nil
            return
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("🛠 ❌ Audio file does not exist: \(url.path)")
            return
        }
        
        do {
            audioPlayer?.stop()
            
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            print("🛠 ✅ Audio session configured for playback")
            
            let tempPlayer = try AVAudioPlayer(contentsOf: url)
            tempPlayer.prepareToPlay()
            let audioDuration = tempPlayer.duration
            print("🛠 ✅ Audio file validation successful - Duration: \(String(format: "%.2f", audioDuration))s")
            
            audioPlayer = tempPlayer
            audioPlayer?.delegate = audioPlayerDelegate
            
            let playSuccess = audioPlayer?.play() ?? false
            if playSuccess {
                print("🛠 ▶️ Playback started successfully for: \(url.lastPathComponent)")
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
    
    // MARK: - Session Management
    
    // 現在のセッションを保存または更新する
    private func saveOrUpdateCurrentSession() {
        if let currentId = historyManager.currentHistoryId {
            historyManager.updateHistoryItem(
                id: currentId,
                lines: transcriptLines,
                fullAudioURL: currentPlayingURL,
                summary: currentSummary,
                subtitle: currentSubtitle
            )
        } else if !transcriptLines.isEmpty {
            historyManager.addHistoryItem(
                lines: transcriptLines,
                fullAudioURL: currentPlayingURL,
                summary: currentSummary,
                subtitle: currentSubtitle
            )
        }
    }
    
    // 新しい文字起こしセッションの準備（内部処理用）
    private func prepareNewSessionInternal(saveCurrentSession: Bool = true) {
        if saveCurrentSession {
            saveOrUpdateCurrentSession()
        }
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isCancelling = false
        currentSummary = nil
        currentSubtitle = nil
        historyManager.currentHistoryId = historyManager.startNewSession()
    }

    private func loadHistoryItem(_ historyItem: HistoryItem) {
        saveOrUpdateCurrentSession()
        
        transcriptLines.removeAll()
        currentPlayingURL = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isCancelling = false
        
        currentSummary = historyItem.summary
        currentSubtitle = historyItem.subtitle
        
        self.transcriptLines = historyItem.getTranscriptLines(audioStorageDirectory: historyManager.audioStorageDirectory)

        if let fullAudio = historyItem.getFullAudioURL(audioStorageDirectory: historyManager.audioStorageDirectory) {
            self.currentPlayingURL = fullAudio
        } else if let firstSegment = self.transcriptLines.first?.audioURL {
            self.currentPlayingURL = firstSegment
        }
        
        if let url = self.currentPlayingURL {
            Debug.log("📁 Loading history audio from: \(url.path)")
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.delegate = audioPlayerDelegate
                audioPlayer?.prepareToPlay()
                Debug.log("✅ History audio loaded successfully")
            } catch {
                print("❌ Failed to load history audio:", error.localizedDescription)
                audioPlayer = nil
                currentPlayingURL = nil
            }
        }
        
        historyManager.currentHistoryId = historyItem.id
        selectedTab = .transcription
        
        if UIDevice.current.userInterfaceIdiom == .phone {
            withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
        }
    }
    
    // MARK: - Share Functions
    private func shareFullText() {
        let text = transcriptLines.map { $0.text }.joined(separator: "\n\n")
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        UIApplication.shared.windows.first?.rootViewController?.present(av, animated: true)
    }
    
    private func shareSummary() {
        guard let summary = currentSummary else { return }
        let av = UIActivityViewController(activityItems: [summary], applicationActivities: nil)
        UIApplication.shared.windows.first?.rootViewController?.present(av, animated: true)
    }
    
    private func shareSubtitle() {
        guard let subtitle = currentSubtitle else { return }
        let av = UIActivityViewController(activityItems: [subtitle], applicationActivities: nil)
        UIApplication.shared.windows.first?.rootViewController?.present(av, animated: true)
    }
    
    // MARK: - Title Update
    private func updateTitleText() {
        if transcriptLines.isEmpty {
            titleText = "Transcriber"
        } else if let firstLine = transcriptLines.first {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d HH:mm"
            formatter.locale = Locale(identifier: "ja_JP")
            titleText = formatter.string(from: firstLine.time)
        } else {
            titleText = "Transcriber"
        }
    }
}

// MARK: - Hamburger Button
struct HamburgerButton: View {
    @Binding var showSidebar: Bool
    var body: some View {
        Button(action: { 
            withAnimation(.easeInOut(duration: 0.2)) { 
                showSidebar.toggle()
                // サイドバー開閉時の振動
                let impactFeedback = UIImpactFeedbackGenerator(style: .soft)
                impactFeedback.impactOccurred()
            }
        }) {
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
    @Binding var showShortMemo: Bool
    var onLoadHistoryItem: (HistoryItem) -> Void
    var onPrepareNewSession: () -> Void
    var onImportAudio: () -> Void
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var selectedHistoryItem: UUID?
    @State private var longPressedItem: HistoryItem?
    @State private var showShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: UIDevice.current.userInterfaceIdiom == .phone ? 20 : 0)
            Text("Transcriber")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 40)

            VStack(alignment: .leading, spacing: 5) {
                SidebarMenuItem(icon: "mic", text: "文字起こし", type: .transcribe, activeMenuItem: $activeMenuItem, action: {
                    if activeMenuItem == .transcribe {
                        // 新規セッションの準備（履歴作成はしない）
                        // 実際の履歴作成は録音開始時に行う
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
                        }
                        return
                    }
                    activeMenuItem = .transcribe
                    closeSidebar()
                })
                SidebarMenuItem(icon: "note.text", text: "ショートメモ", type: .shortMemo, activeMenuItem: $activeMenuItem, action: {
                    activeMenuItem = .shortMemo
                    showShortMemo = true
                    closeSidebar()
                })
                SidebarMenuItem(icon: "square.and.arrow.down", text: "音声インポート", type: .importAudio, activeMenuItem: $activeMenuItem, action: { 
                    onImportAudio()
                    closeSidebar()
                })
                SidebarMenuItem(icon: "doc.on.doc", text: "コピー", type: .copy, activeMenuItem: $activeMenuItem, action: { activeMenuItem = .copy; closeSidebar() })
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
                }
                .padding(.horizontal, 14).padding(.vertical, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(historyManager.historyItems) { item in
                            HistoryRowView(
                                item: item,
                                isSelected: selectedHistoryItem == item.id,
                                onTap: {
                                    selectedHistoryItem = item.id
                                    onLoadHistoryItem(item)
                                },
                                onDelete: {
                                    historyManager.deleteHistoryItem(id: item.id)
                                    if selectedHistoryItem == item.id {
                                        selectedHistoryItem = nil
                                    }
                                }
                            )
                            .onLongPressGesture {
                                longPressedItem = item
                                if let audioURL = item.getFullAudioURL(audioStorageDirectory: historyManager.audioStorageDirectory) {
                                    shareAudioFile(audioURL)
                                }
                            }
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
    
    private func shareAudioFile(_ url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            rootVC.present(av, animated: true)
        }
    }
}

// 新しい HistoryRowView コンポーネント
struct HistoryRowView: View {
    let item: HistoryItem
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    
    @State private var offset: CGFloat = 0
    @State private var isDeletable = false
    @GestureState private var isDragging = false
    
    private let deleteButtonWidth: CGFloat = 70
    
    var body: some View {
        ZStack(alignment: .trailing) {
            // 削除ボタン背景
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        onDelete()
                    }
                }) {
                    VStack {
                        Image(systemName: "trash.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 18))
                    }
                    .frame(width: deleteButtonWidth, height: 44)  // 2行分の高さに調整
                    .background(Color.red)
                }
            }
            
            // メインコンテンツ
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.date.toLocaleString())
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? Color.textPrimary : Color.icon)
                    
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("\(item.transcriptLines.count)件の文字起こし")
                            .font(.system(size: 11))
                            .foregroundColor(Color.textSecondary)
                            .opacity(item.transcriptLines.isEmpty ? 0 : 1)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)  // 最小高さを確保して2行分のスペースを確保
            .background(isSelected ? Color.accent.opacity(0.12) : Color.sidebarBackground)
            .cornerRadius(4)
            .offset(x: offset)
            .gesture(
                DragGesture()
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        if value.translation.width < 0 {
                            offset = max(value.translation.width, -deleteButtonWidth)
                            isDeletable = value.translation.width < -30
                        } else if isDeletable {
                            offset = max(-deleteButtonWidth, min(0, value.translation.width - deleteButtonWidth))
                        }
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.3)) {
                            if value.translation.width < -30 {
                                offset = -deleteButtonWidth
                                isDeletable = true
                            } else {
                                offset = 0
                                isDeletable = false
                            }
                        }
                    }
            )
            .onTapGesture {
                if isDeletable {
                    withAnimation(.spring(response: 0.3)) {
                        offset = 0
                        isDeletable = false
                    }
                } else {
                    onTap()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .clipShape(Rectangle())
    }
}

extension Date {
    func toLocaleString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm:ss"
        return formatter.string(from: self)
    }
}

// MARK: - Sidebar Menu Item
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
                    .font(.system(size: 16, weight: .light))
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

// MARK: - Compact Audio Player View
struct CompactAudioPlayerView: View {
    @Binding var url: URL?
    @Binding var player: AVAudioPlayer?
    var onPlaybackFinished: (() -> Void)?
    var playerDelegate: AudioPlayerDelegateWrapper

    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var duration: TimeInterval = 0.0
    @State private var currentTime: TimeInterval = 0.0
    @State private var isEditingSlider = false 

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 15) {
            Button { togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.circle" : "play.circle")
                    .font(.system(size: 24, weight: .light))
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
        .onChange(of: url) { _, newURL in
            resetPlayer(url: newURL) 
        }
        .onChange(of: player?.isPlaying) { _, newValue in
             if !isEditingSlider {
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

        if isPlaying && !currentPlayingState && duration > 0 {
            if currentTime >= duration - 0.1 || progress >= 0.99 {
                Debug.log("🏁 Timer detected playback finished - progress: \(progress), time: \(currentTime)/\(duration)")
                progress = 1.0
                currentTime = duration
                isPlaying = false
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.onPlaybackFinished?()
                }
            }
        } else if isPlaying != currentPlayingState {
            isPlaying = currentPlayingState
        }
    }
    
    private func resetPlayer(url: URL?) {
        Debug.log("🔄 resetPlayer called with URL: \(url?.lastPathComponent ?? "nil")")
        
        if let currentPlayer = player,
           let currentURL = currentPlayer.url,
           let newURL = url,
           currentURL == newURL {
            Debug.log("✅ Same URL already loaded, skipping resetPlayer")
            duration = currentPlayer.duration
            currentTime = currentPlayer.currentTime
            isPlaying = currentPlayer.isPlaying
            progress = duration > 0 ? currentTime / duration : 0.0
            return
        }
        
        if player != nil {
            Debug.log("🛑 Stopping existing player")
            player?.stop()
            player?.delegate = nil
        }
        
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

// MARK: - Main Content View
struct MainContentView: View {
    @Binding var isRecording: Bool
    @Binding var transcriptLines: [TranscriptLine]
    @Binding var audioPlayerURL: URL?
    @Binding var audioPlayer: AVAudioPlayer?
    let onLineTapped: (URL) -> Void
    let onRetranscribe: (TranscriptLine) -> Void
    let playNextSegmentCallback: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(
                lines: $transcriptLines,
                currentPlayingURL: audioPlayerURL,
                isRecording: isRecording,
                onLineTapped: onLineTapped,
                onRetranscribe: onRetranscribe
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(Color.appBackground.edgesIgnoringSafeArea(.all))
    }
}

// MARK: - Audio Player Delegate Wrapper
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

// MARK: - Enhanced File Picker View
@available(iOS 16.0, *)
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
@available(iOS 16.0, *)
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
