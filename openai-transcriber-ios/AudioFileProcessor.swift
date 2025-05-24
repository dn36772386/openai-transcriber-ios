//
//  AudioFileProcessor.swift
//  openai-transcriber-ios
//
//  Created by apple on 2025/05/24.
//

import Foundation
import AVFoundation
import Accelerate

/// 音声ファイルを読み込んで無音で分割するプロセッサ
final class AudioFileProcessor: ObservableObject {
    
    // MARK: - Types
    struct ProcessingResult {
        let segments: [(url: URL, startTime: TimeInterval, duration: TimeInterval)]
        let totalDuration: TimeInterval
    }
    
    enum ProcessingError: Error {
        case fileNotFound
        case unsupportedFormat
        case conversionFailed
        case processingFailed(String)
    }
    
    // MARK: - Properties
    @Published var isProcessing = false
    @Published var progress: Double = 0.0
    
    private let silenceThreshold: Float = 0.01  // RMS閾値
    private let silenceWindow: TimeInterval = 0.5  // 無音判定時間
    private let minSegmentDuration: TimeInterval = 0.5  // 最小セグメント長
    private let outputFormat: AVAudioFormat
    
    // MARK: - Initialization
    init() {
        // Whisper用の出力フォーマット（16kHz, 16bit, mono）
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }
    
    // MARK: - Public Methods
    
    /// 音声ファイルを処理して無音で分割
    func processFile(at url: URL) async throws -> ProcessingResult {
        await MainActor.run { 
            self.isProcessing = true 
            self.progress = 0.0
        }
        
        defer {
            Task { @MainActor in
                self.isProcessing = false
            }
        }
        
        // セキュリティスコープドリソースアクセス
        guard url.startAccessingSecurityScopedResource() else {
            throw ProcessingError.fileNotFound
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        // ファイルを開く
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        let totalDuration = Double(totalFrames) / inputFormat.sampleRate
        
        print("📁 Processing file: \(url.lastPathComponent)")
        print("📊 Format: \(inputFormat)")
        print("⏱️ Duration: \(totalDuration)s")
        
        // フォーマット変換が必要かチェック
        let needsConversion = inputFormat.sampleRate != outputFormat.sampleRate ||
                            inputFormat.channelCount != outputFormat.channelCount
        
        // バッファサイズ（0.1秒分）
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        
        // 無音検出用の変数
        var segments: [(url: URL, startTime: TimeInterval, duration: TimeInterval)] = []
        var currentSegmentStart: TimeInterval? = nil
        var currentSegmentFrames: [AVAudioPCMBuffer] = []
        var lastSpeechTime: TimeInterval = 0
        var currentTime: TimeInterval = 0
        
        // ファイルを読み込みながら処理
        while file.framePosition < totalFrames {
            // バッファを作成
            let remainingFrames = totalFrames - AVAudioFrameCount(file.framePosition)
            let framesToRead = min(bufferSize, remainingFrames)
            
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: framesToRead
            ) else { continue }
            
            // ファイルから読み込み
            try file.read(into: buffer, frameCount: framesToRead)
            
            // RMS計算
            let rms = calculateRMS(buffer: buffer)
            let isSpeech = rms > silenceThreshold
            
            // 発話検出ロジック
            if isSpeech {
                // 発話開始
                if currentSegmentStart == nil {
                    currentSegmentStart = currentTime
                    currentSegmentFrames = []
                    print("🎤 Speech started at \(currentTime)s")
                }
                currentSegmentFrames.append(buffer)
                lastSpeechTime = currentTime
                
            } else if let segmentStart = currentSegmentStart {
                // 無音検出
                let silenceDuration = currentTime - lastSpeechTime
                
                if silenceDuration >= silenceWindow {
                    // セグメント確定
                    let segmentDuration = lastSpeechTime - segmentStart
                    
                    if segmentDuration >= minSegmentDuration {
                        // セグメントを保存
                        if let segmentURL = try await saveSegment(
                            frames: currentSegmentFrames,
                            inputFormat: inputFormat,
                            startTime: segmentStart,
                            duration: segmentDuration
                        ) {
                            segments.append((
                                url: segmentURL,
                                startTime: segmentStart,
                                duration: segmentDuration
                            ))
                            print("💾 Saved segment: \(segmentStart)s - \(lastSpeechTime)s")
                        }
                    }
                    
                    // リセット
                    currentSegmentStart = nil
                    currentSegmentFrames = []
                }
            }
            
            // 時間を更新
            currentTime += Double(buffer.frameLength) / inputFormat.sampleRate
            
            // 進捗更新
            await MainActor.run {
                self.progress = currentTime / totalDuration
            }
        }
        
        // 最後のセグメントを処理
        if let segmentStart = currentSegmentStart {
            let segmentDuration = currentTime - segmentStart
            if segmentDuration >= minSegmentDuration {
                if let segmentURL = try await saveSegment(
                    frames: currentSegmentFrames,
                    inputFormat: inputFormat,
                    startTime: segmentStart,
                    duration: segmentDuration
                ) {
                    segments.append((
                        url: segmentURL,
                        startTime: segmentStart,
                        duration: segmentDuration
                    ))
                }
            }
        }
        
        print("✅ Processing complete: \(segments.count) segments")
        
        return ProcessingResult(
            segments: segments,
            totalDuration: totalDuration
        )
    }
    
    // MARK: - Private Methods
    
    /// バッファのRMSを計算
    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        
        var rms: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        
        // 全チャンネルのRMSを平均
        for channel in 0..<channelCount {
            var channelRMS: Float = 0
            vDSP_rmsqv(channelData[channel], 1, &channelRMS, vDSP_Length(frameLength))
            rms += channelRMS
        }
        
        return rms / Float(channelCount)
    }
    
    /// セグメントをファイルに保存
    private func saveSegment(
        frames: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat,
        startTime: TimeInterval,
        duration: TimeInterval
    ) async throws -> URL? {
        
        guard !frames.isEmpty else { return nil }
        
        // 一時ファイルURL
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment_\(UUID().uuidString).wav")
        
        // 出力ファイルを作成
        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )
        
        // フォーマット変換が必要な場合
        if inputFormat != outputFormat {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ProcessingError.conversionFailed
            }
            
            // 各フレームを変換して書き込み
            for frame in frames {
                let outputFrameCapacity = AVAudioFrameCount(
                    Double(frame.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
                )
                
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: outputFrameCapacity
                ) else { continue }
                
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return frame
                }
                
                if status == .error {
                    print("⚠️ Conversion error: \(error?.localizedDescription ?? "Unknown")")
                    continue
                }
                
                try outputFile.write(from: outputBuffer)
            }
        } else {
            // フォーマット変換不要な場合は直接書き込み
            for frame in frames {
                try outputFile.write(from: frame)
            }
        }
        
        return tempURL
    }
    
    /// 一時ファイルをクリーンアップ
    func cleanupTemporaryFiles(urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}