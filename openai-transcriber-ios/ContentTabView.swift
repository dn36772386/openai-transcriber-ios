import SwiftUI

struct ContentTabView: View {
    @Binding var selectedTab: ContentTab 
    
    var body: some View {
        HStack(spacing: 0) {
            TabButton(
                title: "文字起こし",
                isSelected: selectedTab == .transcription,
                action: { selectedTab = .transcription }
            )
            
            TabButton(
                title: "要約",
                isSelected: selectedTab == .summary,
                action: { selectedTab = .summary }
            )
        }
        .frame(height: 44)
        .background(Color.white)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.border),
            alignment: .top
        )
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? Color.textPrimary : Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                
                Rectangle()
                    .frame(height: 2)
                    .foregroundColor(isSelected ? Color.textPrimary : Color.clear)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}