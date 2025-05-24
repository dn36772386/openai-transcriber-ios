import SwiftUI

struct TranscriptView: View {
    @Binding var lines: [TranscriptLine]
    var onLineTapped: (URL) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            // 時刻表示 (秒まで表示し、幅を調整)
                            Text(line.time.formatted(.dateTime.hour().minute().second()))
                                .font(.caption)
                                .foregroundColor(.textSecondary)
                                .frame(width: 65, alignment: .leading) // 幅を調整
                            
                            // テキスト内容
                            Text(line.text)
                                .font(.system(size: 14))
                                .foregroundColor(.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id(line.id)
                        .onTapGesture {
                            // audioURLがあればコールバックを呼ぶ
                            if let url = line.audioURL {
                                onLineTapped(url)
                            }
                        }
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
    }
}