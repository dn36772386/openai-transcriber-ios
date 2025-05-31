import SwiftUI

struct TranscriptView: View {
    @Binding var lines: [TranscriptLine]
    var currentPlayingURL: URL?
    var isRecording: Bool
    var onLineTapped: (URL) -> Void
    var onRetranscribe: (TranscriptLine) -> Void
    
    @State private var currentTappedLineId: UUID?
    @State private var selectedLineId: UUID?
    @State private var showActionSheet = false
    
    
    var body: some View {
        ZStack {
            if lines.isEmpty && !isRecording {
                // 空の状態の表示（要約ビューと同じスタイル）
                VStack(spacing: 20) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    
                    Text("録音を開始してください")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    Text("右上のマイクをタップして\n音声の録音を開始します")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty && isRecording {
                // 録音中の表示
                VStack(spacing: 20) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    
                    Text("録音中...")
                        .font(.headline)
                        .foregroundColor(.gray)
                    
                    Text("話し終わったら右上の ✓ をタップ")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                TranscriptLineRow(
                                    line: line,
                                    isSelected: selectedLineId == line.id,
                                    isPlaying: line.audioURL != nil && line.audioURL == currentPlayingURL,
                                    onTap: {
                                        if let url = line.audioURL {
                                            // 同じ行をタップした場合は停止、別の行なら再生
                                            if currentTappedLineId == line.id && currentPlayingURL == url {
                                                // 停止処理（ContentViewで実装）
                                                onLineTapped(URL(fileURLWithPath: ""))  // 空のURLで停止を通知
                                                currentTappedLineId = nil
                                            } else {
                                                onLineTapped(url)
                                                currentTappedLineId = line.id
                                            }
                                        }
                                    },
                                    onLongPress: {
                                        selectedLineId = line.id
                                        showActionSheet = true
                                    }
                                )
                                .id(line.id)
                            }
                        }
                    }
                    .onChange(of: lines.count) { _, _ in
                        if let last = lines.last { 
                            proxy.scrollTo(last.id, anchor: .bottom) 
                        }
                    }
                }
            }
        }
        .background(Color.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.border, lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .confirmationDialog(
            "アクション選択",
            isPresented: $showActionSheet,
            titleVisibility: .visible
        ) {
            if let lineId = selectedLineId,
               let line = lines.first(where: { $0.id == lineId }) {
                Button("再度文字起こし") {
                    onRetranscribe(line)
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }
}

// 個別の行ビュー
struct TranscriptLineRow: View {
    let line: TranscriptLine
    let isSelected: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(line.time.formatted(.dateTime.hour().minute().second()))
                .font(.caption)
                .foregroundColor(.textSecondary)
                .frame(width: 65, alignment: .leading)
            
            Text(line.text)
                .font(.system(size: 14))
                .foregroundColor(isPlaying ? .blue : (isSelected ? .white : .textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isPlaying ? Color.blue.opacity(0.1) :
            (isSelected ? Color.blue : Color.clear)
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.border.opacity(0.5))
                .padding(.leading, 16),
            alignment: .bottom
        )
        .onTapGesture { onTap() }
        .onLongPressGesture { onLongPress() }
    }
}