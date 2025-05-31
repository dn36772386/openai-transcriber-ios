import SwiftUI

struct ContentTabView: View {
    @Binding var selectedTab: ContentTab 
    
    var body: some View {
        HStack(spacing: 0) {
            TabButton(
                title: "文字起こし",
                icon: "mic.fill",
                isSelected: selectedTab == .transcription,
                action: { selectedTab = .transcription }
            )
            
            TabButton(
                title: "要約",
                icon: "doc.text.fill",
                isSelected: selectedTab == .summary,
                action: { selectedTab = .summary }
            )
        }
        .frame(height: 50)
        .background(Color.white)
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundColor(isSelected ? Color.accent : Color.gray)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                VStack {
                    Spacer()
                    Rectangle()
                        .frame(height: 2)
                        .foregroundColor(isSelected ? Color.accent : Color.clear)
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}