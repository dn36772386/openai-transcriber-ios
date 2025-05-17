//  RecorderProxy.swift
//  openai-transcriber-ios
//
//  AudioEngineRecorderDelegate を struct 画面から安全に受け取るためのブリッジ

import Foundation

@MainActor   // delegate 経由で UI を直接触れるようにしておく
final class RecorderProxy: NSObject, AudioEngineRecorderDelegate {
    
    /// セグメント完了時に呼ばれるクロージャ
    var onSegment: ((URL, Date) -> Void)?
    
    nonisolated func recorder(_ rec: AudioEngineRecorder,
                              didFinishSegment url: URL,
                              start: Date) {
        // isolated → MainActor へジャンプして UI/State を触る
        Task { @MainActor in
            onSegment?(url, start)
        }
    }
}
