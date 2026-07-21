import SwiftUI
import UIKit

// MARK: - Colors

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// A color that resolves differently in light vs dark mode.
    static func dynamic(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { trait in
            UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let aeroCyan = Color(hex: 0x3FC6FF)
    static let aeroBlue = Color(hex: 0x1E7FE0)
    static let aeroPink = Color(hex: 0xFF7BD5)
    static let aeroPurple = Color(hex: 0xB07BFF)
    /// Tint/accent — bright cyan in the dark for high contrast, deep blue in light.
    static let aeroAccent = Color.dynamic(light: 0x1E7FE0, dark: 0x39E0FF)
}

extension UIColor {
    convenience init(rgb: UInt) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Background

/// The signature backdrop. Light: Frutiger-Aero aqua→green with pink/purple
/// glows. Dark: a high-contrast vaporwave night — deep indigo with neon cyan/
/// magenta/purple glows. Both carry floating glass bubbles.
struct AeroBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(colors: baseGradient, startPoint: .top, endPoint: .bottom)

            RadialGradient(colors: [glowA.opacity(scheme == .dark ? 0.45 : 0.55), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: scheme == .dark ? 420 : 560)
                .blendMode(scheme == .dark ? .plusLighter : .screen)
            RadialGradient(colors: [glowB.opacity(scheme == .dark ? 0.4 : 0.5), .clear],
                           center: .bottomLeading, startRadius: 8, endRadius: scheme == .dark ? 440 : 600)
                .blendMode(scheme == .dark ? .plusLighter : .screen)
            if scheme == .dark {
                RadialGradient(colors: [Color(hex: 0x7C3AED).opacity(0.28), .clear],
                               center: .center, startRadius: 8, endRadius: 380)
                    .blendMode(.plusLighter)
            }

            BubbleField()
        }
        .ignoresSafeArea()
    }

    private var baseGradient: [Color] {
        scheme == .dark
            ? [Color(hex: 0x0A0F2C), Color(hex: 0x170A2E), Color(hex: 0x04121F)]
            : [Color(hex: 0x9BE8FF), Color(hex: 0x6FB8F5), Color(hex: 0xA6E9A9)]
    }
    private var glowA: Color { scheme == .dark ? Color(hex: 0x22D3EE) : .aeroPink }
    private var glowB: Color { scheme == .dark ? Color(hex: 0xFF2D95) : .aeroPurple }
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
    @Environment(\.colorScheme) private var scheme
    let size: CGFloat

    private var strokeColor: Color { scheme == .dark ? Color.aeroCyan.opacity(0.75) : Color.white.opacity(0.55) }
    private var fillColor: Color { scheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.12) }

    var body: some View {
        Circle()
            .fill(fillColor)
            .overlay(Circle().strokeBorder(strokeColor, lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.white.opacity(scheme == .dark ? 0.6 : 0.8))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .padding(size * 0.15)
                    .blur(radius: 1)
            }
    }
}

// MARK: - Glass surfaces

/// Frosted glass row background for Lists/Forms. `.ultraThinMaterial` already
/// adapts to light/dark; the border brightens in the dark for contrast.
struct GlassRow: View {
    @Environment(\.colorScheme) private var scheme

    private var borderColors: [Color] {
        scheme == .dark
            ? [.white.opacity(0.45), Color.aeroCyan.opacity(0.25)]
            : [.white.opacity(0.7), .white.opacity(0.15)]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(scheme == .dark ? 0.04 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: borderColors, startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .padding(.vertical, 2)
    }
}

extension View {
    /// Frosted glass card (material + glossy stroke).
    func aeroGlass(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.15)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
    }

    /// Aero backdrop behind a scrollable screen, hiding the opaque system list
    /// background so it shows through.
    func aeroScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AeroBackground())
    }
}

// MARK: - Buttons

/// Glossy aqua "aqua button". Neon-cyan glow in the dark, soft blue in light.
struct AeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    LinearGradient(colors: [Color.dynamic(light: 0x3FC6FF, dark: 0x22D3EE),
                                            Color.dynamic(light: 0x1E7FE0, dark: 0x2563EB)],
                                   startPoint: .top, endPoint: .bottom)
                    LinearGradient(colors: [.white.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .center)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: Color.dynamic(light: 0x1E7FE0, dark: 0x22D3EE).opacity(0.5), radius: 10, y: 4)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
