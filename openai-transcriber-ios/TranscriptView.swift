//  TranscriptView.swift
//  openai-transcriber-ios
//
import SwiftUI

struct TranscriptLine: Identifiable {
    let id = UUID()
    var time: Date
    var text: String
}

struct TranscriptView: View {
    @Binding var lines: [TranscriptLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        Text("\(line.time.toLocaleString()) \(line.text)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: lines.count) { _ in
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
