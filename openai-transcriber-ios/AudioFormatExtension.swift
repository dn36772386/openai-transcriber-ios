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

// MARK: - Audio Format Handler
final class AudioFormatHandler {
    
    // サポートする音声フォーマット
    static let supportedFormats: [UTType] = [
        // Core Audio がネイティブサポート
        .wav,           // WAV
        .aiff,          // AIFF
        .mp3,           // MP3
        .mpeg4Audio,    // M4A, AAC
        .audio,         // 汎用音声
        
        // 追加フォーマット
        .flac,          // FLAC
        .ogg,           // OGG Vorbis
        .opus,          // Opus
        .m4a,           // M4A (明示的)
        
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
    
    /// ファイルフォーマットを検証
    static func validateFormat(url: URL) -> (isValid: Bool, formatInfo: FormatInfo?, error: String?) {
        let fileExtension = url.pathExtension.lowercased()
        
        // 拡張子からフォーマット情報を取得
        guard let formatInfo = formatDetails[fileExtension] else {
            return (false, nil, "サポートされていないファイル形式です: .\(fileExtension)")
        }
        
        // ファイルが実際に音声として読み込めるか確認
        do {
            let _ = try AVAudioFile(forReading: url)
            return (true, formatInfo, nil)
        } catch {
            // AVAssetで再試行（動画ファイルの場合）
            let asset = AVAsset(url: url)
            let audioTracks = asset.tracks(withMediaType: .audio)
            
            if !audioTracks.isEmpty {
                return (true, formatInfo, nil)
            } else if asset.tracks(withMediaType: .video).isEmpty {
                return (false, formatInfo, "音声トラックが見つかりません")
            } else {
                return (false, formatInfo, "ファイルを開けません: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Format Conversion
    
    /// 音声を抽出または変換（必要に応じて）
    static func extractAudio(from url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: url)
        
        // 音声トラックの確認
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            completion(.failure(NSError(
                domain: "AudioFormat",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "音声トラックが見つかりません"]
            )))
            return
        }
        
        // 動画ファイルかどうかチェック
        let hasVideo = !asset.tracks(withMediaType: .video).isEmpty
        
        if hasVideo {
            // 動画から音声を抽出
            extractAudioFromVideo(asset: asset, completion: completion)
        } else {
            // 音声ファイルはそのまま返す（AVAudioFileで読めるもの）
            do {
                let _ = try AVAudioFile(forReading: url)
                completion(.success(url))
            } catch {
                // フォーマット変換が必要な場合
                convertAudioFormat(from: url, completion: completion)
            }
        }
    }
    
    /// 動画から音声を抽出
    private static func extractAudioFromVideo(asset: AVAsset, completion: @escaping (Result<URL, Error>) -> Void) {
        let composition = AVMutableComposition()
        
        guard let audioTrack = asset.tracks(withMediaType: .audio).first,
              let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            completion(.failure(NSError(
                domain: "AudioFormat",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "音声トラックの作成に失敗しました"]
            )))
            return
        }
        
        do {
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
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
            
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    completion(.success(outputURL))
                case .failed:
                    completion(.failure(exportSession.error ?? NSError(
                        domain: "AudioFormat",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "エクスポートに失敗しました"]
                    )))
                default:
                    completion(.failure(NSError(
                        domain: "AudioFormat",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "エクスポートがキャンセルされました"]
                    )))
                }
            }
            
        } catch {
            completion(.failure(error))
        }
    }
    
    /// 音声フォーマットを変換
    private static func convertAudioFormat(from url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        // AVAssetを使用した汎用変換
        let asset = AVAsset(url: url)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("converted_\(UUID().uuidString).m4a")
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            completion(.failure(NSError(
                domain: "AudioFormat",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "フォーマット変換に対応していません"]
            )))
            return
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(.success(outputURL))
            case .failed:
                completion(.failure(exportSession.error ?? NSError(
                    domain: "AudioFormat",
                    code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "フォーマット変換に失敗しました"]
                )))
            default:
                completion(.failure(NSError(
                    domain: "AudioFormat",
                    code: -8,
                    userInfo: [NSLocalizedDescriptionKey: "変換がキャンセルされました"]
                )))
            }
        }
    }
    
    // MARK: - Metadata Extraction
    
    /// 音声ファイルのメタデータを取得
    static func getAudioMetadata(from url: URL) -> AudioMetadata? {
        let asset = AVAsset(url: url)
        
        // 基本情報
        let duration = CMTimeGetSeconds(asset.duration)
        let audioTracks = asset.tracks(withMediaType: .audio)
        
        guard let audioTrack = audioTracks.first else { return nil }
        
        // フォーマット情報を取得
        let formatDescriptions = audioTrack.formatDescriptions as? [CMFormatDescription] ?? []
        guard let formatDescription = formatDescriptions.first else { return nil }
        
        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        
        return AudioMetadata(
            duration: duration,
            sampleRate: audioStreamBasicDescription?.mSampleRate ?? 0,
            channelCount: Int(audioStreamBasicDescription?.mChannelsPerFrame ?? 0),
            bitRate: audioTrack.estimatedDataRate,
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
