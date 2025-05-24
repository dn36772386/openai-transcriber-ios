import Foundation
import AVFoundation // ◀︎◀︎ AVFoundation をインポート


final class RecorderProxy: NSObject, AudioEngineRecorderDelegate {

    /// セグメント完了時に呼ばれるクロージャ
    var onSegment: ((URL, Date) -> Void)?

    func recorder(_ rec: AudioEngineRecorder, didFinishSegment url: URL, start: Date) {
        // メインスレッドに切り替えて onSegment を呼び出す
        DispatchQueue.main.async {
            self.onSegment?(url, start)
        }
    }
}