import SwiftUI

/// Original Backlit artwork shared by the app and generated icon assets.
struct BrandGlyph: View {
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(LinearGradient(colors: [Color(white: 0.24), .black],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.16)
                .stroke(.white.opacity(0.35), lineWidth: size * 0.035)
                .frame(width: size * 0.54, height: size * 0.49)
                .offset(y: size * 0.01)
            RoundedRectangle(cornerRadius: size * 0.025)
                .fill(.white)
                .frame(width: size * 0.175, height: size * 0.175)
                .shadow(color: .white.opacity(0.35), radius: size * 0.14)
            Capsule()
                .fill(.white.opacity(0.55))
                .frame(width: size * 0.64, height: size * 0.027)
                .offset(y: size * 0.30)
        }
        .frame(width: size, height: size)
    }
}
