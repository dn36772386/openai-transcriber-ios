import SwiftUI

struct WelcomeGuideView: View {
    var body: some View {
        VStack(spacing: 20) {
            // マイクアイコン
            Image(systemName: "mic.circle")
                .font(.system(size: 60, weight: .thin))
                .foregroundColor(Color.textSecondary.opacity(0.5))
            
            // タイトル
            Text("録音を開始しましょう")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Color.textPrimary)
            
            // 説明文
            VStack(spacing: 8) {
                Text("右上の")
                    .font(.system(size: 14))
                    .foregroundColor(Color.textSecondary)
                +
                Text(" ⭕ ")
                    .font(.system(size: 14))
                    .foregroundColor(Color.textPrimary)
                +
                Text("ボタンをタップ")
                    .font(.system(size: 14))
                    .foregroundColor(Color.textSecondary)
                
                Text("録音が開始されます")
                    .font(.system(size: 14))
                    .foregroundColor(Color.textSecondary)
            }
            
            // 矢印（右上を指す）
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width * 0.6, y: 0))
                    path.addQuadCurve(
                        to: CGPoint(x: geometry.size.width * 0.9, y: -geometry.size.height * 0.3),
                        control: CGPoint(x: geometry.size.width * 0.8, y: -geometry.size.height * 0.2)
                    )
                }
                .stroke(
                    Color.textSecondary.opacity(0.3),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: [5, 5]
                    )
                )
                
                // 矢印の先端
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Color.textSecondary.opacity(0.3))
                    .rotationEffect(.degrees(45))
                    .position(x: geometry.size.width * 0.9, y: -geometry.size.height * 0.3)
            }
            .frame(height: 50)
        }
        .padding(40)
        .onAppear {
            UserDefaults.standard.set(true, forKey: "hasShownWelcomeGuide")
        }
    }
}
