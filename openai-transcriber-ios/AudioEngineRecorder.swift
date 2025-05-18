import Foundation
import AVFoundation
import Accelerate

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

    func start() throws {
        guard !isRecording else { return }
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                        mode: .default,
                                                        options: .defaultToSpeaker)
        try AVAudioSession.sharedInstance().setActive(true)
        startDate = Date()
        installTap()
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finalizeSegment()              // 残りを flush
        isRecording = false
    }

    // MARK: ––––– Private –––––
    private let engine           = AVAudioEngine()
    /// 無音判定しきい値（環境ノイズがある程度あっても切れないよう緩和）
    private let silenceThreshold = Float(0.005)   // ≒ –40 dBFS
    /// 無音継続時間（発話終了判定）
    private let silenceWindow    = 0.8            // 800 ms
    /// Whisper へ送らない極短ファイル（ノイズのみなど）サイズ下限
    private let minSegmentBytes  = 2048           // < 2 kB は破棄

    /// true なら現在「発話区間」にいる
    private var inSpeech = false

    private var audioFile: AVAudioFile?
    private var fileURL:  URL?
    private var silenceStart: Date?
    private var startDate  = Date()

    private func installTap() {
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0,
                                    bufferSize: 1024,
                                    format: fmt) { [weak self] buf, _ in
            self?.process(buffer: buf, format: fmt)
        }
    }

    private func process(buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        // RMS 計算（Accelerate C API を使用）
        guard let ch = buffer.floatChannelData?[0] else { return }
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
        let now = Date()

        // 無音判定
        if rms < silenceThreshold {
            if silenceStart == nil { silenceStart = now }
        } else {
            silenceStart = nil
        }

        // ---- open / write / close ------------------------------------
        if rms >= silenceThreshold {
            // ─ 発話を検知 ─
            if !inSpeech {
                inSpeech = true
                openNewSegment(format: format)   // 声が出た瞬間にだけ開く
            }
            silenceStart = nil                  // 無音タイマをリセット
        } else if inSpeech {
            // ─ 無音区間（発話後） ─
            if silenceStart == nil { silenceStart = now }
            if let s0 = silenceStart,
               now.timeIntervalSince(s0) > silenceWindow {
                finalizeSegment()               // トレーリング無音で確定
                inSpeech = false
            }
        }

        // 音がしている間だけ書き込む
        // ───── 録音ファイルの開始 ─────
        if audioFile == nil { openNewSegment(format: format) }
        try? audioFile?.write(from: buffer)        // in-speech 時のみ呼ばれる

        // segment close
        if let s0 = silenceStart,
           now.timeIntervalSince(s0) > silenceWindow {
            finalizeSegment()                      // トレーリング無音で確定
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

        // ===== ファイルサイズチェック =============================
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                     as? NSNumber)?.intValue ?? 0
        if bytes < minSegmentBytes {
            try? FileManager.default.removeItem(at: url)   // 極小ファイルは破棄
            resetState()
            return
        }

        // ===== ヘッダーを確定させてからデリゲート通知 ================
        audioFile?.close()                         // 追加：強制フラッシュ

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
}
