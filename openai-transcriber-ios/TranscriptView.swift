//  TranscriptView.swift
//  openai-transcriber-ios
//
import SwiftUI

// TranscriptView.swift の以下の部分を削除します
// struct TranscriptLine: Identifiable {
//     let id = UUID()
//     var time: Date
//     var text: String
//     var audioURL: URL? = nil
// }

struct TranscriptView: View {
    @Binding var lines: [TranscriptLine]
    // --- ▼▼▼ 追加 ▼▼▼ ---
    var onLineTapped: (URL) -> Void // タップ時にURLを渡すコールバック
    // --- ▲▲▲ 追加 ▲▲▲ ---

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        Text("\(line.time.toLocaleString()) \(line.text)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                            // --- ▼▼▼ 追加 ▼▼▼ ---
                            .padding(.vertical, 2) // タップしやすくするため少しパディング
                            .onTapGesture {
                                // audioURLがあればコールバックを呼ぶ
                                if let url = line.audioURL {
                                    onLineTapped(url)
                                }
                            }
                            // --- ▲▲▲ 追加 ▲▲▲ ---
                    }
                }
                .padding(8)
            }
            .onChange(of: lines.count) { // ← 変更後 (iOS 17+)
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
