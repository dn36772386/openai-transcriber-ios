import Foundation
import AVFoundation
// import VoiceActivityDetector   // ← 削除
import Accelerate

// private let vad = ...          // ← 削除

protocol AudioEngineRecorderDelegate: AnyObject {
    func recorder(_ rec: AudioEngineRecorder,
                  didFinishSegment url: URL,
                  start: Date)
}

final class AudioEngineRecorder: ObservableObject {
    // MARK: Public
    @Published var isRecording = false
    weak var delegate: AudioEngineRecorderDelegate?

    // MARK: ––––– Private –––––
    // UserDefaultsから設定を読み込むように変更
    private var silenceWindow: Double {
        let value = UserDefaults.standard.double(forKey: "silenceWindow")
        return value > 0 ? value : 0.5
    }
    
    private let minSegmentBytes = 12_288
    
    private var silenceThreshold: Float {
        let value = UserDefaults.standard.float(forKey: "silenceThreshold")
        return value > 0 ? value : 0.01
    }
    
    // 最小セグメント時間を追加
    private var minSegmentDuration: Double {
        let value = UserDefaults.standard.double(forKey: "minSegmentDuration")
        return value > 0 ? value : 0.5
    }

    // 設定値のログ出力フラグ（static）
    private static var hasLoggedSettings = false

    private var isSpeaking  = false
    private var silenceStart: Date?
    private var audioFile:  AVAudioFile?
    private var fileURL:    URL?
    private var startDate   = Date()
    private let engine = AVAudioEngine() // ◀︎◀︎ インスタンス化

    // ◀︎◀︎ 追加: フォーマット変換用プロパティ ▼▼
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    // --- ▼▼▼ ステップ1で追加 ▼▼▼ ---
    private var isCancelled = false // キャンセルフラグ
    // --- ▲▲▲ ステップ1で追加 ▲▲▲ ---
    private var isManualMode = false // 手動モードフラグ

    // MARK: - 初期化 ------------------------------------------------
    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .measurement,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        // ◀︎◀︎ 追加: 出力フォーマットを定義 ▼▼
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, // 16-bit Int
            sampleRate: 16_000,           // 16 kHz
            channels: 1,                  // Mono
            interleaved: true
        )!
    }

    // --- ▼▼▼ 変更 ▼▼▼ ---
    // start メソッドの修正版（バックグラウンド録音対応）
    func start(isManual: Bool) throws {
        guard !isRecording else { return }
        self.isManualMode = isManual
        isCancelled = false

        // バックグラウンド録音対応のAudioSession設定
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        
        // バックグラウンドでも録音を継続
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)

        // フォーマット設定
        self.inputFormat = format
        if let inputFmt = inputFormat, let outputFmt = outputFormat {
            if inputFmt.sampleRate != outputFmt.sampleRate || 
            inputFmt.commonFormat != outputFmt.commonFormat {
                self.audioConverter = AVAudioConverter(from: inputFmt, to: outputFmt)
            } else {
                self.audioConverter = nil
            }
        }

        // タップをインストール
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            if self?.isManualMode == true {
                self?.processManualAudio(buffer)
            } else {
                self?.processAudio(buffer)
            }
        }

        engine.prepare()
        try engine.start()

        startDate = Date()
        isRecording = true
        
        print("🎙️ Recording started in \(isManual ? "manual" : "auto") mode")
        print("🎙️ Input format: \(format)")
        print("🎙️ Output format: \(String(describing: outputFormat))")
    }

    // --- ▼▼▼ 変更 ▼▼▼ ---
    // stop() は「完了」として扱います
    func stop() {
        guard isRecording else { return }
        isCancelled = false // 正常停止（完了）なのでフラグは false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finalizeSegment()
        isRecording = false
    }

    // --- ▼▼▼ 追加 ▼▼▼ ---
    // キャンセルメソッド
    func cancel() {
        guard isRecording else { return }
        isCancelled = true // キャンセルフラグを立てる
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // キャンセル時は現在のファイルを削除
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            Debug.log("🗑️ Cancelled & Deleted:", url.lastPathComponent)
        }
        
        finalizeSegment() // 状態リセットのために呼ぶ
        isRecording = false
    }
    // --- ▲▲▲ 追加 ▲▲▲ ---

    // --- ▼▼▼ 追加 ▼▼▼ ---
    /// 手動モードで音声データを処理する
    private func processManualAudio(_ buffer: AVAudioPCMBuffer) {
        guard !isCancelled else { return } // キャンセル中は処理しない

        // まだファイルを開いていなければ開く（一度だけ）
        if audioFile == nil {
            openNewSegment()
        }
        
        // フォーマット変換
        let bufferToWrite: AVAudioPCMBuffer
        if let converter = audioConverter, let outputFmt = outputFormat {
            bufferToWrite = convertBuffer(buffer, using: converter, to: outputFmt)
        } else {
            bufferToWrite = buffer
        }
        
        // ファイルに書き込み
        try? audioFile?.write(from: bufferToWrite)
    }
    // --- ▲▲▲ 追加 ▲▲▲ ---

    /// RMS値で音声区間を判定しセグメントを切り出す
    private func processAudio(_ buffer: AVAudioPCMBuffer) {
        // --- ▼▼▼ 追加 ▼▼▼ ---
        guard !isCancelled else { return } // キャンセル中は処理しない
        // --- ▲▲▲ 追加 ▲▲▲ ---

        let rms = buffer.rmsMagnitude() // RMS値を取得
        let now = Date()

        // 初回のみ設定値をログ出力（static変数を外部に移動）
        if !AudioEngineRecorder.hasLoggedSettings {
            Debug.log("🎛️ Audio Settings - Threshold: \(silenceThreshold), Window: \(silenceWindow)s, MinDuration: \(minSegmentDuration)s")
            AudioEngineRecorder.hasLoggedSettings = true
        }

        // Debug.log(String(format: "🎙️ RMS = %.5f (threshold: %.5f)", rms, silenceThreshold)) // 頻繁なログを削除

        // 閾値を超えたら「発話中」とみなす
        let isVoice = rms > silenceThreshold

        if isVoice {
            // ─ 発話継続 ─
            if audioFile == nil {
                openNewSegment() // 新規セグメント開始（フォーマット引数を削除）
            }
            
            // ◀︎◀︎ 追加: フォーマット変換を行う ▼▼
            let bufferToWrite: AVAudioPCMBuffer
            if let converter = audioConverter, let outputFmt = outputFormat {
                // フォーマット変換が必要な場合
                bufferToWrite = convertBuffer(buffer, using: converter, to: outputFmt)
            } else {
                // フォーマット変換が不要な場合
                bufferToWrite = buffer
            }
            try? audioFile?.write(from: bufferToWrite) // 変換後の音声を書き込み
            // ◀︎◀︎ 追加 ▲▲
            
            silenceStart = nil
            isSpeaking   = true
        } else if isSpeaking {
            // ─ 無音開始 ─
            if silenceStart == nil { silenceStart = now }
            // 無音が一定時間続いたらセグメントを確定
            if let s0 = silenceStart, now.timeIntervalSince(s0) > silenceWindow {
                // セグメントの長さをチェック
                let segmentDuration = now.timeIntervalSince(startDate)
                if segmentDuration >= minSegmentDuration {
                    finalizeSegment()
                } else {
                    Debug.log("⏩ Segment too short (\(String(format: "%.2f", segmentDuration))s < \(minSegmentDuration)s), discarding")
                    resetState()
                }
                isSpeaking = false
            }
        }
    }

    // openNewSegment, finalizeSegment, resetState は VAD 版と同様
    // openNewSegment メソッドの修正版
    private func openNewSegment() {
        guard !isCancelled else { return }
        guard let outputFmt = outputFormat else { return }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        do {
            // WAVファイルとして明示的に作成
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: outputFmt.settings,
                commonFormat: outputFmt.commonFormat,
                interleaved: outputFmt.isInterleaved
            )
            
            self.fileURL = fileURL
            self.startDate = Date()
            
            print("📝 Created new audio file: \(fileURL.lastPathComponent)")
            print("📝 Format: \(outputFmt)")
            
        } catch {
            print("❌ Failed to create audio file: \(error)")
        }
    }

    // finalizeSegment メソッドの修正版
    private func finalizeSegment() {
        guard let url = fileURL else { resetState(); return }

        if isCancelled {
            try? FileManager.default.removeItem(at: url)
            Debug.log("🗑️ Finalize skipped/deleted due to cancel:", url.path)
            resetState()
            return
        }

        // ファイルを閉じる
        audioFile = nil
        
        // ファイルサイズを確認
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                    as? NSNumber)?.intValue ?? 0
        
        // セグメントの時間長を計算
        let segmentDuration = Date().timeIntervalSince(startDate)
        
        print("📊 Segment finalized: \(url.lastPathComponent), size: \(bytes) bytes, duration: \(String(format: "%.2f", segmentDuration))s")

        // バイト数と時間長の両方でチェック
        if bytes < minSegmentBytes || segmentDuration < minSegmentDuration {
            try? FileManager.default.removeItem(at: url)
            print("🗑️ Segment too small/short, deleted: \(url.lastPathComponent)")
            resetState()
            return
        }

        // AVAudioFileを使用してファイルの整合性を確認
        do {
            let testFile = try AVAudioFile(forReading: url)
            print("✅ Audio file valid: duration=\(Double(testFile.length) / testFile.fileFormat.sampleRate)s")
        } catch {
            print("❌ Audio file validation failed: \(error)")
            try? FileManager.default.removeItem(at: url)
            resetState()
            return
        }

        let segmentURL = url
        let segmentStartDate = startDate
        
        // 状態をリセット
        fileURL = nil
        silenceStart = nil
        isSpeaking = false

        // デリゲートに通知
        delegate?.recorder(self, didFinishSegment: segmentURL, start: segmentStartDate)
        startDate = Date()
    }

    private func resetState() {
        audioFile    = nil
        fileURL      = nil
        silenceStart = nil
        startDate    = Date()
        // --- ▼▼▼ 追加 ▼▼▼ ---
        isCancelled  = false // 状態リセット時にフラグもリセット
        isSpeaking   = false
        isManualMode = false // モードもリセット
    }

    // ◀︎◀︎ 追加: フォーマット変換メソッド ▼▼
    private func convertBuffer(_ inputBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer {
        let outputFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return inputBuffer // 変換失敗時は元のバッファを返す
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if status == .error {
            Debug.log("⚠️ フォーマット変換エラー: \(error?.localizedDescription ?? "Unknown")")
            return inputBuffer // 変換失敗時は元のバッファを返す
        }
        
        return outputBuffer
    }
    // ◀︎◀︎ 追加 ▲▲

    deinit { /* 何も不要 */ }
}
