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

    init() {
        //engine = AVAudioEngine() // engineの初期化はクラスのプロパティ宣言で行われているため不要

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

        try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                                                        mode: .default,
                                                        options: .defaultToSpeaker)
        try AVAudioSession.sharedInstance().setActive(true)

        // ── Tap を設定（まだ付いていなければ）────────────────
        let input  = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)                      // 念のためクリア

        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buffer, time in
            let rms = buffer.rmsMagnitude()
            Debug.log(String(format: "🎙️ in-RMS = %.5f", rms))
            self?.process(buffer: buffer, format: format)
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

    // MARK: ––––– Private –––––
    private let engine           = AVAudioEngine()
    /// 無音判定しきい値（環境ノイズがある程度あっても切れないよう緩和）
    private let silenceThreshold = Float(0.005)   // ≒ –40 dBFS
    /// 無音継続時間（発話終了判定）
    private let silenceWindow    = 0.5            // 1200 ms
    /// Whisper へ送らない極短ファイル（ノイズのみなど）サイズ下限
    private let minSegmentBytes  = 6288         // < 12 kB は破棄
    private let minSegmentRMS    = Float(0.003)   // 平均 RMS がこれ未満なら無音扱い

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

        // ===== ファイル健全性チェック =============================
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                     as? NSNumber)?.intValue ?? 0
        // 平均 RMS を計算
        let asset = AVURLAsset(url: url)
        let reader = try? AVAssetReader(asset: asset)
        var avgRMS: Float = 0
        if let track = asset.tracks(withMediaType: .audio).first {
            // 出力設定（32-bit Float / 非インタリーブ）
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                 AVLinearPCMIsFloatKey: true,
                                 AVLinearPCMBitDepthKey: 32,
                                 AVLinearPCMIsNonInterleaved: false]
            )
            if let r = reader, r.canAdd(output) {
                r.add(output)
                r.startReading()
            }
            var samples: Int64 = 0
            while let buf = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(buf) {
                let len = CMBlockBufferGetDataLength(block)
                var data = [Float](repeating: 0, count: len/4)
                CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                           dataLength: len, destination: &data)
                var rms: Float = 0
                vDSP_rmsqv(data, 1, &rms, vDSP_Length(data.count))
                avgRMS += rms * Float(data.count)
                samples += Int64(data.count)
            }
            if samples > 0 { avgRMS /= Float(samples) }
        }

        if bytes < minSegmentBytes || avgRMS < minSegmentRMS {
            try? FileManager.default.removeItem(at: url)   // 無効ファイルは破棄
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
}
