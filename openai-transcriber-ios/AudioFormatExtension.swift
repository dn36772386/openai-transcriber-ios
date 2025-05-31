import Foundation
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Audio Format Support
extension UTType {
    // カスタムUTType定義（iOS 14+で一部のフォーマットに必要）
    static let flac = UTType(filenameExtension: "flac") ?? .audio
    static let ogg = UTType(filenameExtension: "ogg") ?? .audio
    static let opus = UTType(filenameExtension: "opus") ?? .audio
    static let webm = UTType(filenameExtension: "webm") ?? .audio
    static let amr = UTType(filenameExtension: "amr") ?? .audio
    static let wma = UTType(filenameExtension: "wma") ?? .audio
}

// MARK: - ContentView Extension for iOS 15 Compatibility
@available(iOS 15.0, *)
extension ContentView {
    // iOS 16.0未満では機能を無効化
    static let supportedFormats: [UTType] = [.audio]
}

// MARK: - Audio Format Handler
@available(iOS 16.0, *)
final class AudioFormatHandler {
    
    // サポートする音声フォーマット
    static let supportedFormats: [UTType] = [
        // Core Audio がネイティブサポート
        .wav,           // WAV
        .aiff,          // AIFF
        .mp3,           // MP3
        .mpeg4Audio,    // M4A, AAC を含む
        .audio,         // 汎用音声
        
        // 追加フォーマット
        .flac,          // FLAC
        .ogg,           // OGG Vorbis
        .opus,          // Opus
        
        // 動画ファイルから音声抽出
        .mpeg4Movie,    // MP4
        .quickTimeMovie,// MOV
        .movie,         // 汎用動画
    ]
    
    // フォーマット情報
    struct FormatInfo {
        let name: String
        let fileExtension: String
        let isNativelySupported: Bool
        let requiresConversion: Bool
        let description: String
    }
    
    // フォーマット詳細情報
    static let formatDetails: [String: FormatInfo] = [
        "wav": FormatInfo(
            name: "WAV",
            fileExtension: "wav",
            isNativelySupported: true,
            requiresConversion: false,
            description: "非圧縮音声、最高品質"
        ),
        "mp3": FormatInfo(
            name: "MP3",
            fileExtension: "mp3",
            isNativelySupported: true,
            requiresConversion: false,
            description: "最も一般的な圧縮音声"
        ),
        "m4a": FormatInfo(
            name: "M4A/AAC",
            fileExtension: "m4a",
            isNativelySupported: true,
            requiresConversion: false,
            description: "Apple標準の圧縮音声"
        ),
        "aiff": FormatInfo(
            name: "AIFF",
            fileExtension: "aiff",
            isNativelySupported: true,
            requiresConversion: false,
            description: "非圧縮音声（Apple）"
        ),
        "flac": FormatInfo(
            name: "FLAC",
            fileExtension: "flac",
            isNativelySupported: true, // iOS 11+
            requiresConversion: false,
            description: "可逆圧縮音声"
        ),
        "ogg": FormatInfo(
            name: "OGG Vorbis",
            fileExtension: "ogg",
            isNativelySupported: false,
            requiresConversion: true,
            description: "オープンソース圧縮音声"
        ),
        "mp4": FormatInfo(
            name: "MP4",
            fileExtension: "mp4",
            isNativelySupported: true,
            requiresConversion: false,
            description: "動画ファイル（音声抽出）"
        ),
        "mov": FormatInfo(
            name: "QuickTime",
            fileExtension: "mov",
            isNativelySupported: true,
            requiresConversion: false,
            description: "動画ファイル（音声抽出）"
        )
    ]
    
    // MARK: - Format Validation
    
    struct ValidationResult {
        let isValid: Bool
        let formatInfo: FormatInfo?
        let error: String?
    }
    
    /// ファイルフォーマットを検証（async版）
    static func validateFormat(url: URL) async -> ValidationResult {
        let fileExtension = url.pathExtension.lowercased()
        
        // 拡張子からフォーマット情報を取得
        guard let formatInfo = formatDetails[fileExtension] else {
            return ValidationResult(isValid: false, formatInfo: nil, error: "サポートされていないファイル形式です: .\(fileExtension)")
        }
        
        // ファイルが実際に音声として読み込めるか確認
        do {
            let _ = try AVAudioFile(forReading: url)
            print("✅ [validateFormat] AVAudioFile successfully read \(url.lastPathComponent)")
            return ValidationResult(isValid: true, formatInfo: formatInfo, error: nil)
        } catch {
            print("⚠️ [validateFormat] AVAudioFile failed for \(url.lastPathComponent): \(error.localizedDescription)") // ◀︎◀︎ エラー内容を記録
            // AVAssetで再試行（動画ファイルの場合）
            let asset = AVAsset(url: url)
            do { // 🔽 try を使うために do-catch を追加
                let audioTracks = try await asset.loadTracks(withMediaType: .audio) // ◀︎◀︎ try を追加
                
                if !audioTracks.isEmpty {
                    print("✅ [validateFormat] AVAsset found audio tracks for \(url.lastPathComponent)")
                    return ValidationResult(isValid: true, formatInfo: formatInfo, error: nil)
                } else {
                    print("⚠️ [validateFormat] AVAsset found no audio tracks for \(url.lastPathComponent)")
                    let videoTracks = try await asset.loadTracks(withMediaType: .video) // ◀︎◀︎ try を追加
                    if videoTracks.isEmpty {
                        return ValidationResult(isValid: false, formatInfo: formatInfo, error: "音声トラックもビデオトラックも見つかりません")
                    } else {
                        // 動画のみのファイルでも音声トラックがなければエラー（要件に応じて変更）
                        return ValidationResult(isValid: false, formatInfo: formatInfo, error: "音声トラックが見つかりません (ビデオのみ)")
                    }
                }
            } catch { // ◀︎◀︎ エラーハンドリングを追加
                print("⚠️ [validateFormat] AVAsset failed for \(url.lastPathComponent): \(error.localizedDescription)") // ◀︎◀︎ エラー内容を記録
                return ValidationResult(isValid: false, formatInfo: formatInfo, error: "ファイルを開けません (AVAsset): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Format Conversion
    
    /// 音声を抽出または変換（async版）
    static func extractAudio(from url: URL) async throws -> URL {
        let asset = AVAsset(url: url)
        
        // 音声トラックの確認
        let audioTracks = try await asset.loadTracks(withMediaType: .audio) // ◀︎◀︎ try を追加
        guard !audioTracks.isEmpty else {
            throw NSError(
                domain: "AudioFormat",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "音声トラックが見つかりません"]
            )
        }
        
        // 動画ファイルかどうかチェック
        let videoTracks = try await asset.loadTracks(withMediaType: .video) // ◀︎◀︎ try を追加
        let hasVideo = !videoTracks.isEmpty
        
        if hasVideo {
            // 動画から音声を抽出
            return try await extractAudioFromVideo(asset: asset)
        } else {
            // 音声ファイルはそのまま返す（AVAudioFileで読めるもの）
            do {
                let _ = try AVAudioFile(forReading: url)
                return url
            } catch {
                // フォーマット変換が必要な場合
                return try await convertAudioFormat(from: url)
            }
        }
    }
    
    /// 動画から音声を抽出
    private static func extractAudioFromVideo(asset: AVAsset) async throws -> URL {
        let composition = AVMutableComposition()
        
        let audioTracks = try await asset.loadTracks(withMediaType: .audio) // ◀︎◀︎ try を追加
        guard let audioTrack = audioTracks.first,
              let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw NSError(
                domain: "AudioFormat",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "音声トラックの作成に失敗しました"]
            )
        }
        
        do {
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            
            // エクスポート設定
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("extracted_\(UUID().uuidString).m4a")
            
            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw NSError(
                    domain: "AudioFormat",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "エクスポートセッションの作成に失敗"]
                )
            }
            
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            
            await exportSession.export()
            
            switch exportSession.status {
            case .completed:
                return outputURL
            case .failed:
                throw exportSession.error ?? NSError(
                    domain: "AudioFormat",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "エクスポートに失敗しました"]
                )
            default:
                throw NSError(
                    domain: "AudioFormat",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "エクスポートがキャンセルされました"]
                )
            }
        } catch {
            throw error
        }
    }
    
    /// 音声フォーマットを変換
    private static func convertAudioFormat(from url: URL) async throws -> URL {
        // AVAssetを使用した汎用変換
        let asset = AVAsset(url: url)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("converted_\(UUID().uuidString).m4a")
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "AudioFormat",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "フォーマット変換に対応していません"]
            )
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        await exportSession.export()
        
        switch exportSession.status {
        case .completed:
            return outputURL
        case .failed:
            throw exportSession.error ?? NSError(
                domain: "AudioFormat",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "フォーマット変換に失敗しました"]
            )
        default:
            throw NSError(
                domain: "AudioFormat",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "変換がキャンセルされました"]
            )
        }
    }
    
    // MARK: - Metadata Extraction
    
    /// 音声ファイルのメタデータを取得（async版）
    static func getAudioMetadata(from url: URL) async -> AudioMetadata? {
        let asset = AVAsset(url: url)
        
        // 基本情報
        let duration = try? await asset.load(.duration) // ◀︎◀︎ try? を追加
        let durationSeconds = duration.map { CMTimeGetSeconds($0) } ?? 0
        let audioTracks = try? await asset.loadTracks(withMediaType: .audio) // ◀︎◀︎ try? を追加
        
        guard let audioTrack = audioTracks?.first else { return nil } // ◀︎◀︎ オプショナルチェーンに変更
        
        // フォーマット情報を取得
        let formatDescriptions = try? await audioTrack.load(.formatDescriptions) // ◀︎◀︎ try? を追加
        guard let formatDescription = formatDescriptions?.first else { return nil } // ◀︎◀︎ オプショナルチェーンに変更
        
        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        let estimatedDataRate = try? await audioTrack.load(.estimatedDataRate) // ◀︎◀︎ try? を追加
        
        return AudioMetadata(
            duration: durationSeconds,
            sampleRate: audioStreamBasicDescription?.mSampleRate ?? 0,
            channelCount: Int(audioStreamBasicDescription?.mChannelsPerFrame ?? 0),
            bitRate: estimatedDataRate ?? 0,
            fileSize: getFileSize(at: url),
            codec: getCodecName(from: formatDescription)
        )
    }
    
    struct AudioMetadata {
        let duration: TimeInterval
        let sampleRate: Double
        let channelCount: Int
        let bitRate: Float
        let fileSize: Int64
        let codec: String
        
        var formattedDuration: String {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
        
        var formattedFileSize: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: fileSize)
        }
        
        var formattedBitRate: String {
            return "\(Int(bitRate / 1000)) kbps"
        }
    }
    
    private static func getFileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return 0
        }
        return fileSize.int64Value
    }
    
    private static func getCodecName(from formatDescription: CMFormatDescription) -> String {
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        
        switch mediaSubType {
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        default: return "Unknown"
        }
    }
}
