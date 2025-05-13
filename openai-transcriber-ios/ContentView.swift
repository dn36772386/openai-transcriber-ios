//
//  ContentView.swift
//  openai-transcriber-ios
//
//  Created by apple on 2025/05/13.
//

import SwiftUI

// CSSカラーパレットの定義
extension Color {
    static let appBackground = Color(hex: "#f7f7f8")
    static let sidebarBackground = Color(hex: "#ffffff")
    static let accent = Color(hex: "#10a37f")
    static let icon = Color(hex: "#334155")
    static let hover = Color(hex: "#111827") // SwiftUIでは直接的なhoverは異なるアプローチ
    static let border = Color(hex: "#e5e7eb")
    static let danger = Color(hex: "#dc2626")
    static let cardBackground = Color(hex: "#ffffff")
    static let textPrimary = Color(hex: "#222222")
    static let textSecondary = Color(hex: "#6b7280")
}

// 16進数カラーコードからColorを生成するイニシャライザ
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}


struct ContentView: View {
    @State private var showSidebar = UIDevice.current.userInterfaceIdiom != .phone // iPadなら最初から表示
    @State private var showApiKeyModal = false
    @State private var modeIsManual = false
    @State private var activeMenuItem: SidebarMenuItemType? = .transcribe // 初期選択

    var body: some View {
        ZStack {
            NavigationView {
                MainContentView(
                    modeIsManual: $modeIsManual,
                    showApiKeyModal: $showApiKeyModal,
                    isRecording: .constant(false) // 実際の録音状態を渡す
                )
                .navigationBarItems(
                    leading: HamburgerButton(showSidebar: $showSidebar),
                    trailing: HeaderRecordingControls(isRecording: .constant(false), modeIsManual: $modeIsManual) // メインコンテンツから移動
                )
                .navigationTitle("") // タイトルはヘッダー内で表示
                .navigationBarTitleDisplayMode(.inline)
                .background(Color.appBackground.edgesIgnoringSafeArea(.all))
            }
            .navigationViewStyle(StackNavigationViewStyle()) // iPadでの挙動を調整

            // Sidebar
            if showSidebar {
                SidebarView(
                    showSidebar: $showSidebar,
                    showApiKeyModal: $showApiKeyModal,
                    activeMenuItem: $activeMenuItem
                )
                .transition(.move(edge: .leading))
                .zIndex(1) // Sidebarを前面に
            }

            // Backdrop for phone
            if showSidebar && UIDevice.current.userInterfaceIdiom == .phone {
                Color.black.opacity(0.35)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        withAnimation {
                            showSidebar = false
                        }
                    }
                    .zIndex(0.5) // Sidebarより後ろ、MainContentより前
            }
        }
        .sheet(isPresented: $showApiKeyModal) {
            ApiKeyModalView(showApiKeyModal: $showApiKeyModal)
        }
    }
}

struct HamburgerButton: View {
    @Binding var showSidebar: Bool

    var body: some View {
        Button(action: {
            withAnimation {
                showSidebar.toggle()
            }
        }) {
            Image(systemName: "line.horizontal.3")
                .imageScale(.large)
                .foregroundColor(Color.icon)
        }
    }
}

enum SidebarMenuItemType: CaseIterable {
    case transcribe, proofread, copy, audioDownload, settings
}

struct SidebarView: View {
    @Binding var showSidebar: Bool
    @Binding var showApiKeyModal: Bool
    @Binding var activeMenuItem: SidebarMenuItemType?

    // 履歴アイテムのプレースホルダー
    struct HistoryItem: Identifiable {
        let id = UUID()
        let date: Date
    }
    @State private var historyItems: [HistoryItem] = [
        HistoryItem(date: Date().addingTimeInterval(-3600)),
        HistoryItem(date: Date().addingTimeInterval(-7200))
    ]
    @State private var selectedHistoryItem: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (ロゴ表示エリア)
            Text("Transcriber")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 44) // CSSの #sidebar header の高さに合わせる

            // Menu items
            VStack(alignment: .leading, spacing: 0) {
                SidebarMenuItem(icon: "mic.fill", text: "文字起こし", type: .transcribe, activeMenuItem: $activeMenuItem, action: { /* TODO */ closeSidebar() })
                SidebarMenuItem(icon: "text.badge.checkmark", text: "校正", type: .proofread, activeMenuItem: $activeMenuItem, action: { /* TODO */ closeSidebar() })
                SidebarMenuItem(icon: "doc.on.doc.fill", text: "コピー", type: .copy, activeMenuItem: $activeMenuItem, action: { /* TODO */ closeSidebar() })
                SidebarMenuItem(icon: "arrow.down.circle.fill", text: "音声DL", type: .audioDownload, activeMenuItem: $activeMenuItem, action: { /* TODO */ closeSidebar() })
                SidebarMenuItem(icon: "gearshape.fill", text: "設定", type: .settings, activeMenuItem: $activeMenuItem, action: {
                    showApiKeyModal = true
                    closeSidebar()
                })
            }

            // History Section
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("履歴")
                        .font(.system(size: 14))
                        .foregroundColor(Color.textSecondary)
                    Spacer()
                    Button(action: {
                        // TODO: Clear all history
                        historyItems.removeAll()
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(Color.icon)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .border(width: 1, edges: [.top], color: Color.border)


                List {
                    ForEach(historyItems) { item in
                        HStack {
                            Text(item.date.toLocaleString()) // より詳細なフォーマットが必要
                                .font(.system(size: 13))
                                .foregroundColor(Color.icon)
                            Spacer()
                            Button(action: {
                                // TODO: Delete specific history item
                                historyItems.removeAll(where: { $0.id == item.id })
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(Color.icon)
                                    .opacity(selectedHistoryItem == item.id ? 1 : 0) // ホバーのような効果
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(selectedHistoryItem == item.id ? Color.accent.opacity(0.12) : Color.clear)
                        .onTapGesture {
                            selectedHistoryItem = item.id
                            // TODO: Load history item
                        }
                    }
                }
                .listStyle(PlainListStyle()) // デフォルトのListスタイルを解除
            }
            .padding(.top, 8)


            Spacer() // Pushes content to top
        }
        .frame(width: 240)
        .background(Color.sidebarBackground)
        .border(width: 1, edges: [.trailing], color: Color.border)
        .edgesIgnoringSafeArea(UIDevice.current.userInterfaceIdiom == .phone ? .vertical : []) // iPhoneでは上下無視
    }

    private func closeSidebar() {
        if UIDevice.current.userInterfaceIdiom == .phone {
            withAnimation {
                showSidebar = false
            }
        }
    }
}

// Date extension for toLocaleString (simplified)
extension Date {
    func toLocaleString() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: self)
    }
}


struct SidebarMenuItem: View {
    let icon: String
    let text: String
    let type: SidebarMenuItemType
    @Binding var activeMenuItem: SidebarMenuItemType?
    let action: () -> Void

    var isActive: Bool {
        activeMenuItem == type
    }

    var body: some View {
        Button(action: {
            activeMenuItem = type
            action()
        }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18)) // アイコンサイズ調整
                    .frame(width: 24, alignment: .center)
                    .foregroundColor(isActive ? Color.accent : Color.icon)
                Text(text)
                    .font(.system(size: 15)) // 文字サイズ調整
                    .foregroundColor(isActive ? Color.accent : Color.icon)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isActive ? Color.accent.opacity(0.1) : Color.clear) // アクティブ時の背景
            .overlay(
                HStack { // Active indicator line
                    if isActive {
                        Rectangle()
                            .fill(Color.accent)
                            .frame(width: 4)
                    }
                    Spacer()
                }
            )
        }
    }
}

struct HeaderRecordingControls: View {
    @Binding var isRecording: Bool
    @Binding var modeIsManual: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(modeIsManual ? "manual" : "auto")
                    .font(.system(size: 12)) // modeLabel
                    .foregroundColor(Color.textPrimary)
                Toggle("", isOn: $modeIsManual)
                    .labelsHidden()
                    .scaleEffect(0.8) // トグルを少し小さく
                    .tint(Color.accent)
            }

            if !isRecording {
                Button(action: { isRecording = true }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Color.icon) // 通常時の色
                }
            } else {
                HStack(spacing: 8) {
                    Button(action: { isRecording = false /* TODO: Finish recording */ }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color.accent) // 確定ボタンの色
                    }
                    Button(action: { isRecording = false /* TODO: Cancel recording */ }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color.danger) // キャンセルボタンの色
                    }
                }
            }
        }
    }
}


struct MainContentView: View {
    @Binding var modeIsManual: Bool
    @Binding var showApiKeyModal: Bool
    @Binding var isRecording: Bool

    @State private var transcriptionResult: String = "" // "ここに文字起こし結果が表示されます..."

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar (NavigationViewが担当するので、ここではコンテンツのみ)
            // ロゴはSidebarに移動、録音制御はNavigationBarItemsに移動

            // Content Area
            VStack(spacing: 8) { // CSSのgap:8px
                Text("残り 0:00") // Counter placeholder
                    .font(.system(size: 12))
                    .foregroundColor(Color.textSecondary)
                    .padding(.top, 14) // CSSの .section margin-bottom:14px の代わり

                ZStack(alignment: .topLeading) {
                     TextEditor(text: $transcriptionResult)
                        .font(.system(size: 15))
                        .lineSpacing(5) // line-height: 1.6 の近似
                        .padding(8)
                        .background(Color.cardBackground)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.border, lineWidth: 1)
                        )
                    if transcriptionResult.isEmpty {
                         Text("ここに文字起こし結果が表示されます...")
                            .font(.system(size: 15))
                            .foregroundColor(Color.gray.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity)


                // Audio Player (Simplified placeholder)
                HStack {
                    Button(action: { /* Play/Pause */ }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color.icon)
                    }
                    Slider(value: .constant(0.5)) // Placeholder for scrubber
                        .tint(Color.accent)
                    Text("00:00 / 00:00")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textSecondary)
                    Button(action: { /* Volume */ }) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color.icon)
                    }
                }
                .padding(12)
                .background(Color.cardBackground) // プレーヤーの背景
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.border, lineWidth: 1)
                )
                .padding(.bottom, 14) // CSSの .section margin-bottom:14px の代わり

            }
            .padding(.horizontal, 18) // CSSの #main padding:18px
        }
        .background(Color.appBackground.edgesIgnoringSafeArea(.all))
    }
}

struct ApiKeyModalView: View {
    @Binding var showApiKeyModal: Bool
    @State private var apiKey: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                Text("OpenAI APIキー")
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.bottom, 6)
                SecureField("sk-...", text: $apiKey)
                    .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6))
                    .background(Color.white)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.border, lineWidth: 1)
                    )
                Button("保存") {
                    // TODO: Save API Key logic
                    showApiKeyModal = false
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accent)
                .foregroundColor(.white)
                .cornerRadius(4)
                .padding(.top, 10)
                Spacer()
            }
            .padding(16)
            .frame(width: 260)
            .background(Color.white)
            .cornerRadius(6)
            .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 4)
            .navigationBarItems(trailing: Button("閉じる") {
                showApiKeyModal = false
            })
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("APIキー設定")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3).edgesIgnoringSafeArea(.all))
    }
}

// EdgeBorder extension for applying border to specific edges
struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat {
                switch edge {
                case .top, .bottom, .leading: return rect.minX
                case .trailing: return rect.maxX - width
                }
            }

            var y: CGFloat {
                switch edge {
                case .top, .leading, .trailing: return rect.minY
                case .bottom: return rect.maxY - width
                }
            }

            var w: CGFloat {
                switch edge {
                case .top, .bottom: return rect.width
                case .leading, .trailing: return self.width
                }
            }

            var h: CGFloat {
                switch edge {
                case .top, .bottom: return self.width
                case .leading, .trailing: return rect.height
                }
            }
            path.addPath(Path(CGRect(x: x, y: y, width: w, height: h)))
        }
        return path
    }
}

extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(EdgeBorder(width: width, edges: edges).foregroundColor(color))
    }
}

#Preview {
    ContentView()
}
