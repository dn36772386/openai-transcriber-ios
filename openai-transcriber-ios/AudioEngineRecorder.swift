import Foundation
import AVFoundation
import Speech
import VoiceActivityDetector   // WebRTC VAD ラッパ
import Accelerate              // vDSP（RMS 計算など）で使用

/// ── WebRTC VAD インスタンス ─────────────────────────
private let vad = VoiceActivityDetector(
    sampleRate: 16_000,
    aggressiveness: .quality)  // .quality / .aggressive / .veryAggressive

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
    private let silenceWindow   = 1.2           // 発話終了判定 1.2 sec
    private let minSegmentBytes = 12_288        // 12 kB 未満は破棄

    /// 直近フレームで VAD が voice を返したか
    private var voiceFlag = false

    private var isSpeaking  = false
    private var silenceStart: Date?
    private var audioFile:  AVAudioFile?
    private var fileURL:    URL?
    private var startDate   = Date()

    /// 入力用オーディオ・エンジン
    private let engine = AVAudioEngine

// MARK: - 初期化 ------------------------------------------------
    init() {
        // ── AudioSession 構成を明示 ─────────────────────────
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .measurement,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        // Tap は start() で付けるように変更（重複回避）
    }

    func start() throws {
        guard !isRecording else { return }

        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .default,
            options: .defaultToSpeaker)
        try AVAudioSession.sharedInstance().setActive(true)

        // ── Tap を設定（まだ付いていなければ）────────────────
        let input  = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)                      // 念のためクリア

        // Tap in start (bufferSize 1024), replacing RMS logic
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processVAD(buffer)                 // VAD でスピーチ判定
            let rms = buffer.rmsMagnitude()          // 参考ログ
            Debug.log(String(format: "🎙️ RMS = %.5f", rms))
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
        let floatPCM = (0..<n).map { i -> Float in
            ch[i] * Float(Int16.max)
        }
        var pcm = [Int16](repeating: 0, count: n)
        vDSP.convert(                     // Xcode-15 以降の代替 API
            elementsOf: floatPCM,
            to: &pcm,
            rounding: .towardNearestInteger)

        // VAD でチェック
        voiceFlag = false
        var idx = 0
        let frameSize = 160 // 10 ms at 16 kHz
        while idx + frameSize <= n {
            let voiced = pcm.withUnsafeBufferPointer {
                vad.detect(frames: $0.baseAddress!.advanced(by: idx),
                           lengthInMilliSec: 10)          // DetectionResult
            }
            if voiced == .voice {          // .voice / .silence
                voiceFlag = true        // プロパティにセット
                break
            }
            idx += frameSize
        }

        let now = Date()

        if voiceFlag {
            // ─ 発話継続 ─
            if audioFile == nil {
                openNewSegment(format: buffer.format)   // 新規セグメント開始
            }
            try? audioFile?.write(from: buffer) // 音声を書き込み
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

        if bytes < minSegmentBytes {            // 極短 or 無音ファイルは破棄
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
