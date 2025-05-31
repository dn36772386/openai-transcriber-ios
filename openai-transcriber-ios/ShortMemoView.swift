import SwiftUI
import AVFoundation
import Combine

struct ShortMemoView: View {
    @StateObject private var memoRecorder = ShortMemoRecorder()
    @State private var memoText = ""
    @State private var isRecording = false
    @State private var memoLines: [MemoLine] = []
    @State private var showError = false
    @State private var errorMessage = ""
    @Environment(\.dismiss) private var dismiss
    
    struct MemoLine: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // メモ一覧
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(memoLines) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text(line.time.formatted(.dateTime.hour().minute().second()))
                                    .font(.caption)
                                    .foregroundColor(.textSecondary)
                                    .frame(width: 65, alignment: .leading)
                                
                                Text(line.text)
                                    .font(.system(size: 14))
                                    .foregroundColor(.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .id(line.id)
                        }
                    }
                }
                .onChange(of: memoLines.count) {
                    if let last = memoLines.last { 
                        proxy.scrollTo(last.id, anchor: .bottom) 
                    }
                }
            }
            .background(Color.cardBackground)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.border, lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            
            // 録音ボタン
            Button(action: toggleRecording) {
                Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(isRecording ? .red : .accent)
            }
            .padding(.vertical, 20)
            .disabled(memoRecorder.isProcessing)
        }
        .navigationTitle("ショートメモ")
        .navigationBarTitleDisplayMode(.inline)
        .alert("エラー", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onReceive(memoRecorder.$transcribedText) { text in
            if !text.isEmpty {
                memoLines.append(MemoLine(time: Date(), text: text))
                memoRecorder.transcribedText = "" // リセット
            }
        }
        .onReceive(memoRecorder.$error) { error in
            if let error = error {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        .onTapGesture {
            saveMemoToHistory()
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            memoRecorder.stopRecording()
        } else {
            memoRecorder.startRecording()
        }
        isRecording.toggle()
    }
    
    private func saveMemoToHistory() {
        // メモを履歴に保存する処理
        let lines = memoLines.map { memo in
            TranscriptLine(
                id: UUID(),
                time: memo.time,
                text: memo.text,
                audioURL: nil
            )
        }
        
        HistoryManager.shared.addHistoryItem(
            lines: lines,
            fullAudioURL: nil,
            summary: nil,
            subtitle: "ショートメモ - \(Date().formatted(.dateTime.month().day()))"
        )
    }
}

// ショートメモ用の録音クラス
class ShortMemoRecorder: ObservableObject {
    @Published var isProcessing = false
    @Published var transcribedText = ""
    @Published var error: Error?
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private let openAIClient = OpenAIClient()
    private var transcriptionTask: UUID?
    private var cancellable: AnyCancellable?
    
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("memo_\(UUID().uuidString).wav")
            
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
            
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            recordingURL = url
            print("🎤 ShortMemo recording started: \(url.lastPathComponent)")
            
        } catch {
            print("Failed to start recording: \(error)")
        }
        
        // 文字起こし結果の通知を受信
        cancellable = NotificationCenter.default.publisher(for: .transcriptionDidFinish)
            .sink { [weak self] notification in
                self?.handleTranscriptionResult(notification: notification)
            }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        
        guard let url = recordingURL else { return }
        
        isProcessing = true
        transcriptionTask = UUID()
        
        Task {
            do {
                // WhisperAPIで文字起こし
                try await MainActor.run {
                    try openAIClient.transcribeInBackground(url: url, started: Date())
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.error = error
                    print("Transcription failed: \(error)")
                }
            }
        }
    }
    
    private func handleTranscriptionResult(notification: Notification) {
        guard let url = notification.object as? URL,
              url == recordingURL else { return }
        
        DispatchQueue.main.async {
            self.isProcessing = false
            
            if let error = notification.userInfo?["error"] as? Error {
                self.error = error
            } else if let text = notification.userInfo?["text"] as? String {
                self.transcribedText = text
            }
            
            // 一時ファイルを削除
            try? FileManager.default.removeItem(at: url)
        }
    }
}
