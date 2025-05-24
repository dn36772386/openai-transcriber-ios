import Foundation

@MainActor   // delegate 経由で UI を直接触れるようにしておく
final class RecorderProxy: NSObject, AudioEngineRecorderDelegate {

    /// セグメント完了時に呼ばれるクロージャ
    var onSegment: ((URL, Date) -> Void)?

    func recorder(_ rec: AudioEngineRecorder, didFinishSegment url: URL, start: Date) {
        // OpenAIService を直接呼ばず、設定されたクロージャを呼び出す
        onSegment?(url, start)
    }
}
