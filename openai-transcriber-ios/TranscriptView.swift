import SwiftUI

struct TranscriptView: View {
    @Binding var lines: [TranscriptLine]
    var currentPlayingURL: URL?  // この行を追加
    var onLineTapped: (URL) -> Void
    var onRetranscribe: (TranscriptLine) -> Void  // 追加
    
    @State private var selectedLineId: UUID?
    @State private var showActionSheet = false
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        TranscriptLineRow(
                            line: line,
                            isSelected: selectedLineId == line.id,
                            isPlaying: line.audioURL == currentPlayingURL,  // ⭐️ 追加
                            onTap: {
                                if let url = line.audioURL {
                                    onLineTapped(url)
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
            .onChange(of: lines.count) {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .background(Color.cardBackground)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.border, lineWidth: 1)
            )
        }
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
    let isPlaying: Bool  // ⭐️ 追加
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
                .foregroundColor(isPlaying ? .blue : (isSelected ? .white : .textPrimary))  // ⭐️ 修正
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isPlaying ? Color.blue.opacity(0.1) :  // ⭐️ 追加
            (isSelected ? Color.blue : Color.clear)
        )
        .onTapGesture { onTap() }
        .onLongPressGesture { onLongPress() }
    }
}