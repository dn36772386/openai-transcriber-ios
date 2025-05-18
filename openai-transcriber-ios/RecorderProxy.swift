//  RecorderProxy.swift
//  openai-transcriber-ios
//
//  AudioEngineRecorderDelegate を struct 画面から安全に受け取るためのブリッジ

import Foundation

@MainActor   // delegate 経由で UI を直接触れるようにしておく
final class RecorderProxy: NSObject, AudioEngineRecorderDelegate {
    
    /// セグメント完了時に呼ばれるクロージャ
    var onSegment: ((URL, Date) -> Void)?
    
    func recorder(_ rec: AudioEngineRecorder, didFinishSegment url: URL, start: Date) {
        Task {
            do {
                let text = try await OpenAIService.transcribe(url: url)
                DispatchQueue.main.async {
                    self.transcribed += text + "\n"
                }
            } catch {
                print("Error transcribing audio: \(error)")
            }
        }
    }
}
