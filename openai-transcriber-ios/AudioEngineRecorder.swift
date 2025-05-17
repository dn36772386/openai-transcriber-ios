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
    private let silenceThreshold = Float(0.003)   // ≒ –45 dBFS
    private let silenceWindow    = 0.5            // 500 ms
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

        // segment open
        if audioFile == nil { openNewSegment(format: format) }
        try? audioFile?.write(from: buffer)

        // segment close
        if let s0 = silenceStart, now.timeIntervalSince(s0) > silenceWindow {
            finalizeSegment()
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
        audioFile = nil
        fileURL   = nil
        silenceStart = nil
        delegate?.recorder(self, didFinishSegment: url, start: startDate)
        startDate = Date()
    }
}
