import AVFoundation
import Foundation

final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published var isRecording = false
    private var recorder: AVAudioRecorder?

    /// 録音開始
    func start() throws {
        // セッション設定
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // 16 kHz / mono / AAC
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        // 保存先パス生成
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "Recording_\(formatter.string(from: Date())).m4a"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.record()
        isRecording = true

        print("[Recorder] start → \(url.path)")
    }

    /// 録音停止
    func stop() {
        recorder?.stop()
        isRecording = false
        if let url = recorder?.url {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 {
                print("[Recorder] saved (\(size) bytes) → \(url.path)")
            } else {
                print("[Recorder] saved → \(url.path)")
            }
        }
    }
}
