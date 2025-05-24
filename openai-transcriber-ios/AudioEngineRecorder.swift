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
    private let silenceWindow   = 1.2
    private let minSegmentBytes = 12_288
    private let silenceThreshold: Float = 0.01 // ◀︎◀︎ 無音と判定するRMS値の閾値（要調整）

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
    func start(isManual: Bool) throws {
        guard !isRecording else { return }
        self.isManualMode = isManual // モードを設定

        // --- ▼▼▼ 追加 ▼▼▼ ---
        isCancelled = false // 開始時にキャンセルをリセット
        // --- ▲▲▲ 追加 ▲▲▲ ---

        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .default,
            options: .defaultToSpeaker)
        try AVAudioSession.sharedInstance().setActive(true)

        let input  = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)

        // ◀︎◀︎ 追加: 入力フォーマットを保存し、コンバーターを初期化 ▼▼
        self.inputFormat = format
        if let inputFmt = inputFormat, let outputFmt = outputFormat {
            // 入力と出力フォーマットが異なる場合のみコンバーターを作成
            if inputFmt.sampleRate != outputFmt.sampleRate || 
               inputFmt.commonFormat != outputFmt.commonFormat {
                self.audioConverter = AVAudioConverter(from: inputFmt, to: outputFmt)
            } else {
                self.audioConverter = nil // フォーマットが同じ場合は変換不要
            }
        }
        // ◀︎◀︎ 追加 ▲▲

        // Tapをインストールし、RMSで音声区間を判定
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // --- ▼▼▼ 変更 ▼▼▼ ---
            if self?.isManualMode == true {
                print("Recorder: Manual mode tap - calling processManualAudio") // ← デバッグ用ログ
                self?.processManualAudio(buffer) // 手動モード処理
            } else {
                print("Recorder: Auto mode tap - calling processAudio") // ← デバッグ用ログ
                self?.processAudio(buffer) // 自動モード処理
            }
            // --- ▲▲▲ 変更 ▲▲▲ ---
        }

        engine.prepare()
        try engine.start()

        startDate = Date()
        isRecording = true
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

        Debug.log(String(format: "🎙️ RMS = %.5f", rms)) // ログ出力

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
                finalizeSegment()
                isSpeaking = false
            }
        }
    }

    // openNewSegment, finalizeSegment, resetState は VAD 版と同様
    private func openNewSegment() {
        // --- ▼▼▼ 追加 ▼▼▼ ---
        guard !isCancelled else { return } // キャンセル中は開かない
        // --- ▲▲▲ 追加 ▲▲▲ ---
        guard let outputFmt = outputFormat else { return }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        audioFile = try? AVAudioFile(
            forWriting: fileURL,
            settings: outputFmt.settings,
            commonFormat: outputFmt.commonFormat,
            interleaved: outputFmt.isInterleaved
        )
        self.fileURL = fileURL
        self.startDate = Date() // 新規セグメント開始時に日付を更新
    }

    private func finalizeSegment() {
        guard let url = fileURL else { resetState(); return } // URLがなければリセットして終了

        // --- ▼▼▼ 変更 ▼▼▼ ---
        // キャンセルされている場合、ファイルを削除してリセット
        if isCancelled {
            try? FileManager.default.removeItem(at: url)
            Debug.log("🗑️ Finalize skipped/deleted due to cancel:", url.path)
            resetState()
            return
        }
        // --- ▲▲▲ 変更 ▲▲▲ ---
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                     as? NSNumber)?.intValue ?? 0

        if bytes < minSegmentBytes { // 極短 or 無音ファイルは破棄
            try? FileManager.default.removeItem(at: url)
            resetState()
            return
        }

        // --- ▼▼▼ 変更 ▼▼▼ ---
        // デリゲート呼び出し後にリセットするように順序を整理
        let segmentURL = url
        let segmentStartDate = startDate
        
        audioFile    = nil
        fileURL      = nil
        silenceStart = nil
        isSpeaking = false // 発話状態もリセット

        delegate?.recorder(self, didFinishSegment: segmentURL, start: segmentStartDate)
        startDate = Date() // 次のセグメントのために開始日時を更新
        // --- ▲▲▲ 変更 ▲▲▲ ---
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
