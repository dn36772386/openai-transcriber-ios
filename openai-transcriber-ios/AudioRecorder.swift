import Foundation
import AVFoundation
import SwiftUI

final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published var isRecording = false
    private var recorder: AVAudioRecorder?
    /// 録音ファイル URL（停止後に ContentView 側から参照）
    var url: URL? { recorder?.url }

    /// 録音開始
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let file = "Recording_\(df.string(from: .init())).m4a"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(file)

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.record()
        isRecording = true

        Debug.log("[Recorder] start →", url.lastPathComponent)
    }

    /// 録音停止
    func stop() {
        if let r = recorder, r.isRecording {
            r.stop()
        }
        isRecording = false
        if let url = recorder?.url,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 {
            Debug.log("[Recorder] saved (\(size) bytes) →", url.lastPathComponent)
        } else {
            Debug.log("[Recorder] stop called but file URL unavailable")
        }
    }
}
