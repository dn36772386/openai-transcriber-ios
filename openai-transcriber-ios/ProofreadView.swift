// ProofreadView.swift
// 新規作成ファイル

import SwiftUI

struct ProofreadView: View {
    @Binding var transcriptLines: [TranscriptLine]
    @State private var editingLineId: UUID?
    @State private var editedText: String = ""
    @State private var showExportOptions = false
    @State private var exportText = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($transcriptLines) { $line in
                        VStack(alignment: .leading, spacing: 6) {
                            // タイムスタンプ
                            HStack {
                                Image(systemName: "clock")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Text(line.time.formatted(.dateTime.hour().minute().second()))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                
                                if editingLineId == line.id {
                                    Text("編集中")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(.horizontal, 16)
                            
                            // テキスト編集エリア
                            if editingLineId == line.id {
                                VStack(spacing: 10) {
                                    TextEditor(text: $editedText)
                                        .font(.system(size: 14))
                                        .frame(minHeight: 80)
                                        .padding(10)
                                        .background(Color.gray.opacity(0.05))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.blue, lineWidth: 1)
                                        )
                                    
                                    HStack(spacing: 12) {
                                        Button("保存") {
                                            withAnimation {
                                                line.text = editedText
                                                editingLineId = nil
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        
                                        Button("キャンセル") {
                                            withAnimation {
                                                editingLineId = nil
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        Spacer()
                                        
                                        // オリジナルテキストをリセット
                                        Button {
                                            editedText = line.text
                                        } label: {
                                            Label("元に戻す", systemImage: "arrow.uturn.backward")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.horizontal, 10)
                                }
                                .padding(.horizontal, 16)
                            } else {
                                // 表示モード
                                Text(line.text)
                                    .font(.system(size: 14))
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.gray.opacity(0.05))
                                    .cornerRadius(8)
                                    .padding(.horizontal, 16)
                                    .onTapGesture {
                                        withAnimation {
                                            editingLineId = line.id
                                            editedText = line.text
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    
                    // 使い方のヒント
                    if transcriptLines.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "text.badge.checkmark")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            
                            Text("校正する文字起こしがありません")
                                .font(.headline)
                                .foregroundColor(.gray)
                            
                            Text("先に音声を録音して文字起こしを行ってください")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                    } else if editingLineId == nil {
                        HStack {
                            Image(systemName: "hand.tap")
                                .font(.caption)
                            Text("テキストをタップして編集")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .padding()
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("校正")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            exportAsText()
                        } label: {
                            Label("テキストとしてエクスポート", systemImage: "doc.text")
                        }
                        
                        Button {
                            exportWithTimestamps()
                        } label: {
                            Label("タイムスタンプ付きでエクスポート", systemImage: "clock.badge.checkmark")
                        }
                        
                        Button {
                            copyAllText()
                        } label: {
                            Label("すべてコピー", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(transcriptLines.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showExportOptions) {
            ShareSheet(activityItems: [exportText])
        }
    }
    
    // エクスポート機能
    private func exportAsText() {
        exportText = transcriptLines
            .map { $0.text }
            .joined(separator: "\n\n")
        showExportOptions = true
    }
    
    private func exportWithTimestamps() {
        exportText = transcriptLines
            .map { line in
                "[\(line.time.formatted(.dateTime.hour().minute().second()))]\n\(line.text)"
            }
            .joined(separator: "\n\n")
        showExportOptions = true
    }
    
    private func copyAllText() {
        let text = transcriptLines
            .map { $0.text }
            .joined(separator: "\n\n")
        UIPasteboard.general.string = text
    }
}

// ShareSheet for iOS
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}