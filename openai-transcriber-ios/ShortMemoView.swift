import SwiftUI
import AVFoundation

struct ShortMemoView: View {
    @StateObject private var memoRecorder = ShortMemoRecorder()
    @State private var memoText = ""
    @State private var isRecording = false
    @State private var memoLines: [MemoLine] = []
    @State private var showError = false
    @State private var errorMessage = ""
    
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
                saveMemoToHistory()
            }
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
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private let openAIClient = OpenAIClient()
    
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("memo_\(UUID().uuidString).m4a")
            
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            recordingURL = url
            
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        
        guard let url = recordingURL else { return }
        
        isProcessing = true
        
        Task {
            do {
                // WhisperAPIで文字起こし
                try await MainActor.run {
                    try openAIClient.transcribeInBackground(url: url, started: Date())
                }
                
                // 文字起こし結果を待つ（簡易実装）
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.isProcessing = false
                    // 実際にはBackgroundSessionManagerからの通知を受け取る
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    print("Transcription failed: \(error)")
                }
            }
        }
    }
}
