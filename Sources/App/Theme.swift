import SwiftUI

// MARK: - Colors

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    static let aeroCyan = Color(hex: 0x3FC6FF)
    static let aeroBlue = Color(hex: 0x1E7FE0)
    static let aeroGreen = Color(hex: 0x8FE07A)
    static let aeroPink = Color(hex: 0xFF7BD5)
    static let aeroPurple = Color(hex: 0xB07BFF)
}

// MARK: - Background

/// The signature Frutiger-Aero-meets-vaporwave backdrop: an aqua→green gradient
/// with soft pink/purple glows and floating glass bubbles.
struct AeroBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x9BE8FF), Color(hex: 0x6FB8F5), Color(hex: 0xA6E9A9)],
                           startPoint: .top, endPoint: .bottom)

            RadialGradient(colors: [Color.aeroPink.opacity(0.55), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 540)
                .blendMode(.screen)
            RadialGradient(colors: [Color.aeroPurple.opacity(0.5), .clear],
                           center: .bottomLeading, startRadius: 8, endRadius: 580)
                .blendMode(.screen)

            BubbleField()
        }
        .ignoresSafeArea()
    }
}

private struct AeroBubbleSpec: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let opacity: Double
    let drift: CGFloat
    let duration: Double
}

/// Decorative floating bubbles. Static positions with a gentle vertical drift.
struct BubbleField: View {
    @State private var animate = false

    private let bubbles: [AeroBubbleSpec] = [
        .init(x: 0.12, y: 0.18, size: 90, opacity: 0.5, drift: 18, duration: 6.5),
        .init(x: 0.82, y: 0.10, size: 60, opacity: 0.45, drift: 14, duration: 5.5),
        .init(x: 0.68, y: 0.30, size: 34, opacity: 0.4, drift: 10, duration: 4.5),
        .init(x: 0.24, y: 0.52, size: 46, opacity: 0.4, drift: 12, duration: 7.0),
        .init(x: 0.90, y: 0.55, size: 74, opacity: 0.4, drift: 16, duration: 6.0),
        .init(x: 0.10, y: 0.80, size: 120, opacity: 0.35, drift: 20, duration: 8.0),
        .init(x: 0.55, y: 0.86, size: 54, opacity: 0.4, drift: 12, duration: 5.0),
        .init(x: 0.78, y: 0.82, size: 40, opacity: 0.45, drift: 10, duration: 4.8),
        .init(x: 0.40, y: 0.14, size: 28, opacity: 0.5, drift: 8, duration: 4.2),
        .init(x: 0.50, y: 0.62, size: 22, opacity: 0.5, drift: 8, duration: 3.8),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(bubbles) { bubble in
                    BubbleShape(size: bubble.size)
                        .frame(width: bubble.size, height: bubble.size)
                        .position(x: bubble.x * geo.size.width, y: bubble.y * geo.size.height)
                        .offset(y: animate ? -bubble.drift : bubble.drift)
                        .opacity(bubble.opacity)
                        .animation(.easeInOut(duration: bubble.duration).repeatForever(autoreverses: true),
                                   value: animate)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }
}

private struct BubbleShape: View {
    let size: CGFloat
    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.12))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .padding(size * 0.15)
                    .blur(radius: 1)
            }
    }
}

// MARK: - Glass surfaces

/// Frosted glass row background for Lists/Forms.
struct GlassRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.15)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .padding(.vertical, 2)
    }
}

extension View {
    /// Frosted glass card (padded content + material + glossy stroke).
    func aeroGlass(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.15)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
    }

    /// Apply the Aero backdrop behind a scrollable screen and hide the opaque
    /// system list/scroll background so it shows through.
    func aeroScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AeroBackground())
    }
}

// MARK: - Buttons

/// Glossy aqua "aqua button" style.
struct AeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    LinearGradient(colors: [Color.aeroCyan, Color.aeroBlue],
                                   startPoint: .top, endPoint: .bottom)
                    LinearGradient(colors: [.white.opacity(0.65), .clear],
                                   startPoint: .top, endPoint: .center)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
            )
            .shadow(color: Color.aeroBlue.opacity(0.4), radius: 8, y: 4)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
