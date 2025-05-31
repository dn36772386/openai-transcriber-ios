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
@available(iOS 16.0, *)
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
    
    // UserDefaultsから設定を読み込むように変更
    private var silenceThreshold: Float {
        let value = UserDefaults.standard.float(forKey: "silenceThreshold")
        return value > 0 ? value : 0.01
    }
    
    private var silenceWindow: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "silenceWindow")
        return value > 0 ? value : 0.5
    }
    
    private var minSegmentDuration: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "minSegmentDuration")
        return value > 0 ? value : 0.5
    }
    
    private let maxSegmentDuration: TimeInterval = 240.0  // 最大セグメント長（4分）
    private let maxSegmentSize: Int64 = 24 * 1024 * 1024  // 最大24MB（APIは25MBまで）
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
        
        Debug.log("📊 AudioFileProcessor: Processing \(url.lastPathComponent)")
        Debug.log("📊 File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        // 設定値をログ出力
        print("📊 Processing with settings:")
        print("   - Silence threshold: \(silenceThreshold)")
        print("   - Silence window: \(silenceWindow)s")
        print("   - Min segment duration: \(minSegmentDuration)s")
        
        // セキュリティスコープドリソースアクセス
        // ローカルファイル（/tmp/内）の場合はセキュリティスコープ不要
        let needsSecurityScope = !url.path.contains("/tmp/")
        
        if needsSecurityScope {
            guard url.startAccessingSecurityScopedResource() else {
                Debug.log("❌ Failed to access security scoped resource")
                throw ProcessingError.fileNotFound
            }
        }
        
        defer { 
            if needsSecurityScope { url.stopAccessingSecurityScopedResource() }
            Debug.log("📊 Stopped accessing security scoped resource (if needed)")
        }
        
        // フォーマット検証
        let validation = await AudioFormatHandler.validateFormat(url: url)
        guard validation.isValid else {
            Debug.log("❌ Format validation failed: \(validation.error ?? "Unknown")")
            throw ProcessingError.unsupportedFormat
        }
        
        // ファイルを開く（AVAssetReader を使用する場合もある）
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
            Debug.log("✅ AVAudioFile opened successfully")
        } catch {
            Debug.log("❌ AVAudioFile failed to open: \(error)")
            // AVAudioFileで開けない場合は、先に変換が必要
            throw ProcessingError.unsupportedFormat
        }
        let inputFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        let totalDuration = Double(totalFrames) / inputFormat.sampleRate
        
        print("📁 Processing file: \(url.lastPathComponent)")
        print("📊 Format: \(inputFormat)")
        print("⏱️ Duration: \(totalDuration)s")
        
        // フォーマット変換が必要かチェック
        let needsConversion = inputFormat.sampleRate != outputFormat.sampleRate ||
                            inputFormat.channelCount != outputFormat.channelCount
        
        // コンバーター作成（必要な場合）
        let converter: AVAudioConverter?
        if needsConversion {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        } else {
            converter = nil
        }
        
        // バッファサイズ（0.1秒分）
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        
        // 無音検出用の変数
        var segments: [(url: URL, startTime: TimeInterval, duration: TimeInterval)] = []
        var currentSegmentStart: TimeInterval? = nil
        var currentSegmentFrames: [AVAudioPCMBuffer] = []
        var lastSpeechTime: TimeInterval = 0
        var currentTime: TimeInterval = 0
        var currentSegmentSize: Int64 = 0
        
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
                // バッファサイズを概算（16bit, 16kHz, mono）
                let bufferSize = Int64(buffer.frameLength) * 2  // 16bit = 2bytes
                let estimatedSegmentSize = currentSegmentSize + bufferSize
                
                // 発話開始
                if currentSegmentStart == nil {
                    currentSegmentStart = currentTime
                    currentSegmentFrames = []
                    print("🎤 Speech started at \(currentTime)s")
                }
                currentSegmentFrames.append(buffer)
                lastSpeechTime = currentTime
                currentSegmentSize += bufferSize
                
                // セグメントが最大サイズまたは最大時間に達した場合、強制的に分割
                let segmentDuration = currentTime - (currentSegmentStart ?? 0)
                if estimatedSegmentSize >= maxSegmentSize || segmentDuration >= maxSegmentDuration {
                    print("⚠️ Force splitting segment: size=\(estimatedSegmentSize/1024/1024)MB, duration=\(segmentDuration)s")
                    
                    if segmentDuration >= minSegmentDuration {
                        if let segmentURL = try await saveSegment(
                            frames: currentSegmentFrames,
                            inputFormat: inputFormat,
                            startTime: currentSegmentStart ?? currentTime,
                            duration: segmentDuration,
                            needsConversion: needsConversion,
                            converter: converter
                        ) {
                            segments.append((
                                url: segmentURL,
                                startTime: currentSegmentStart ?? currentTime,
                                duration: segmentDuration
                            ))
                            print("💾 Saved forced segment: \(currentSegmentStart ?? 0)s - \(currentTime)s")
                        }
                    }
                    
                    // リセット
                    currentSegmentStart = nil
                    currentSegmentFrames = []
                    currentSegmentSize = 0
                }
                
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
                            duration: segmentDuration,
                            needsConversion: needsConversion,
                            converter: converter
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
                    currentSegmentSize = 0
                }
            }
            
            // 時間を更新
            currentTime += Double(buffer.frameLength) / inputFormat.sampleRate
            
            // 進捗更新（currentTimeを安全にキャプチャ）
            let capturedProgress = currentTime / totalDuration
            await MainActor.run {
                self.progress = capturedProgress
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
                    duration: segmentDuration,
                    needsConversion: needsConversion,
                    converter: converter
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
        duration: TimeInterval,
        needsConversion: Bool,
        converter: AVAudioConverter?
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
        if needsConversion, let converter = converter {
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