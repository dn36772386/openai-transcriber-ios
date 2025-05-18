import Foundation
import AVFoundation
import Accelerate
import VoiceActivityDetector   // Swift ラッパ名

protocol AudioEngineRecorderDelegate: AnyObject {
    func recorder(_ rec: AudioEngineRecorder,
                  didFinishSegment url: URL,
                  start: Date)
}

final class AudioEngineRecorder: ObservableObject {
    // MARK: Public
    /// 録音状態
    /// SwiftUI で `Binding` を扱えるよう **setter を公開** します
    @Published var isRecording = false
    weak var delegate: AudioEngineRecorderDelegate?

    // MARK: ––––– Private –––––
    /// 無音判定しきい値（RMS を使う処理を削除したので不要）
    private let silenceThreshold = Float(0.0)     // ダミー値（未使用）
    /// 無音継続時間（発話終了判定）
    private let silenceWindow    = 1.2            // 1200 ms
    /// Whisper へ送らない極短ファイル（ノイズのみなど）サイズ下限
    private let minSegmentBytes  = 12_288         // < 12 kB は破棄

    // ── VoiceActivityDetector ラッパ ──────────────────────────
    private let vad = VoiceActivityDetector()

    // MARK: - 状態 --------------------------------------------------
    private var isSpeaking  = false
    private var silenceStart: Date?
    private var audioFile: AVAudioFile?
    private var fileURL:   URL?

    private let engine: AVAudioEngine

// MARK: - 初期化 ------------------------------------------------
    init() {
        try? vad.setSampleRate(sampleRate: 16_000) // Configure sample rate
        try? vad.setMode(mode: .quality)        // .quality〜.veryAggressive
        engine = AVAudioEngine()

        // ── AudioSession 構成を明示 ─────────────────────────
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .measurement,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let input  = engine.inputNode
        let format = input.outputFormat(forBus: 0) // Format for init tap

        // Tap in init (bufferSize 256)
        input.installTap(onBus: 0, bufferSize: 256, format: format) {
            [weak self] buffer, _ in
            self?.processVAD(buffer)
        }
    }

    func start() throws {
        guard !isRecording else { return }

        try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                        mode: .default, // Or .measurement, ensure consistency
                                                        options: .defaultToSpeaker)
        try AVAudioSession.sharedInstance().setActive(true)

        // ── Tap を設定（まだ付いていなければ）────────────────
        let input  = engine.inputNode
        let format = input.inputFormat(forBus: 0) // Format for start tap, as per older structure
        input.removeTap(onBus: 0)                      // 念のためクリア

        // Tap in start (bufferSize 1024), replacing RMS logic
        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buffer, _ in
            self?.processVAD(buffer)          // RMS 判定ロジックを削除
        }

        // ── Engine 起動 ───────────────────────────────────────
        engine.prepare()
        try engine.start()

        startDate = Date()
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finalizeSegment()              // 残りを flush
        isRecording = false
    }

    /// WebRTC VAD で音声区間を判定しセグメントを切り出す
    private func processVAD(_ buffer: AVAudioPCMBuffer)
    {
        guard let ch  = buffer.floatChannelData?[0] else { return }

        let n = Int(buffer.frameLength)

        // Float → Int16 （vDSP でスケール＆丸め）
        // Create a mutable copy for floatPCM if buffer.floatChannelData provides non-mutable
        var mutableCh = Array(UnsafeBufferPointer(start: ch, count: n))
        var floatPCM = [Float](repeating: 0, count: n) // This intermediate might not be needed if scaling directly to Int16
                                                       // but current diff implies this structure.
        var scale: Float = Float(Int16.max)
        vDSP_vsmul(&mutableCh, 1, &scale, &floatPCM, 1, vDSP_Length(n))
        
        var pcm = [Int16](repeating: 0, count: n)
        vDSP_vfixr32_16(floatPCM, 1, &pcm, 1, vDSP_Length(n))

        var voiceFlag = false
        var idx = 0
        let frameSize = 160
        while idx + frameSize <= n {
            // Fvad は Int32 を返す: 1=voice, 0=silence, -1=error
            // if vad.process(&pcm + idx, length: frameSize) == 1 { // Previous version
            if try vad.process(frame: &pcm + idx, length: frameSize) == .voice {
                voiceFlag = true
                break
            }
            idx += frameSize
        }

        let now = Date()

        if voiceFlag {
            if audioFile == nil { // Start of a new speech segment
                openNewSegment(format: buffer.format) // Use the original buffer's format for file writing,
                                                      // assuming it's what we want to save.
                                                      // Or use a fixed format for WAV.
            }
            try? audioFile?.write(from: buffer) // Write the original buffer
            silenceStart = nil
            isSpeaking   = true
        } else if isSpeaking {
            if silenceStart == nil { silenceStart = now }
            if let s0 = silenceStart,
               now.timeIntervalSince(s0) > silenceWindow {
                finalizeSegment()
                isSpeaking = false
            }
        }
    }

    private func openNewSegment(format: AVAudioFormat) {
        // 16-kHz / Mono / 16-bit Int WAV
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        audioFile = try? AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self.fileURL   = fileURL
    }

    private func finalizeSegment() {
        guard let url = fileURL else { return }

        // ===== ファイル健全性チェック =============================
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                     as? NSNumber)?.intValue ?? 0

        if bytes < minSegmentBytes {   // avgRMS 判定は不要になったので簡略
            try? FileManager.default.removeItem(at: url)
            resetState()
            return
        }

        // ===== ヘッダーを確定させてからデリゲート通知 ================
        //audioFile?.close()                         // 追加：強制フラッシュ

        audioFile    = nil
        fileURL      = nil
        silenceStart = nil
        delegate?.recorder(self, didFinishSegment: url, start: startDate)
        startDate    = Date()
    }

    /// 変数を初期化して次の録音に備える
    private func resetState() {
        audioFile    = nil
        fileURL      = nil
        silenceStart = nil
        startDate    = Date()
    }

    // MARK: - 後片付け -----------------------------------------
    deinit { /* Fvad はクラスなので明示解放不要 */ }
}
