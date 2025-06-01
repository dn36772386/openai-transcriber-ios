import Foundation
import AVFoundation // ◀︎◀︎ AVFoundation をインポート


final class RecorderProxy: NSObject, AudioEngineRecorderDelegate {

    /// セグメント完了時に呼ばれるクロージャ
    var onSegment: ((URL, Date) -> Void)?
    
    /// 音声バッファ受信時に呼ばれるクロージャ（WebSocket用）
    var onAudioBuffer: ((Data) -> Void)?

    func recorder(_ rec: AudioEngineRecorder, didFinishSegment url: URL, start: Date) {
        // メインスレッドに切り替えて onSegment を呼び出す
        DispatchQueue.main.async {
            self.onSegment?(url, start)
        }
    }
    
    func recorder(_ rec: AudioEngineRecorder, didCaptureAudioBuffer buffer: Data) {
        // WebSocketストリーミング用
        onAudioBuffer?(buffer)
    }
}