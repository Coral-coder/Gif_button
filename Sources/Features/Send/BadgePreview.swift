import SwiftUI
import UIKit

/// The signature round preview — a glowing cyan/violet ring around a dark disc
/// that mirrors the badge's round 368×368 display. Shows the chosen GIF/image
/// (animated) or a placeholder.
struct BadgePreview: View {
    var data: Data?
    var size: CGFloat = 240

    var body: some View {
        ZStack {
            Circle().fill(Color.black)

            // Faint radar rings.
            Circle().strokeBorder(Color.white.opacity(0.05), lineWidth: 1).padding(size * 0.10)
            Circle().strokeBorder(Color.white.opacity(0.05), lineWidth: 1).padding(size * 0.22)

            content

            // Glowing rim.
            Circle().strokeBorder(
                AngularGradient(
                    colors: [Color.auraPrimary, Color.auraViolet, Color.auraCyanBright, Color.auraPrimary],
                    center: .center),
                lineWidth: 3)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.auraPrimary.opacity(0.45), radius: 22)
        .shadow(color: Color.auraViolet.opacity(0.30), radius: 30)
    }

    @ViewBuilder private var content: some View {
        if let data, SendMediaView.isGIF(data) {
            AnimatedGIFView(data: data).clipShape(Circle())
        } else if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().clipShape(Circle())
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.16))
                    .foregroundStyle(Color.auraMuted)
                Text("Pick a GIF to preview")
                    .font(.footnote)
                    .foregroundStyle(Color.auraMuted)
            }
        }
    }
}
