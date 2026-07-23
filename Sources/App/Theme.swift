import SwiftUI
import UIKit

// MARK: - Colors
//
// Design adapted from AuraCast (github.com/Manaiakalani/auracast, MIT ©2025
// Felix Herbst) — reimplemented in SwiftUI. Dark-first: near-black surfaces,
// neon cyan primary, violet secondary.

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// Resolves differently in light vs dark.
    static func dynamic(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { trait in
            UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }

    // AuraCast tokens.
    static let auraBg = Color.dynamic(light: 0xF5F4FA, dark: 0x131318)
    static let auraSurface = Color.dynamic(light: 0xFFFFFF, dark: 0x1F1F25)
    static let auraSurfaceHigh = Color.dynamic(light: 0xECEAF2, dark: 0x2A292F)
    static let auraPrimary = Color.dynamic(light: 0x0794A3, dark: 0x00DBE7) // cyan
    static let auraCyanBright = Color(hex: 0x00F2FF)
    static let auraViolet = Color.dynamic(light: 0x8B2FD6, dark: 0xBC00FF)
    static let auraVioletSoft = Color(hex: 0xEBB2FF)
    static let auraText = Color.dynamic(light: 0x1A1A1F, dark: 0xE4E1E9)
    static let auraMuted = Color.dynamic(light: 0x6B6A76, dark: 0x908F9F)
    static let auraOutline = Color.dynamic(light: 0xD3D1DC, dark: 0x3A3944)
    static let auraOnline = Color(hex: 0x00E676)
    static let auraWarning = Color(hex: 0xFFB74D)
    static let auraError = Color(hex: 0xFF5252)

    // Back-compat aliases so existing screens keep compiling.
    static let aeroAccent = Color.auraPrimary
    static let aeroCyan = Color.auraPrimary
    static let aeroBlue = Color.auraPrimary
    static let aeroPink = Color.auraViolet
    static let aeroPurple = Color.auraViolet
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

/// Clean near-black canvas with faint cyan/violet elevation glows.
struct AeroBackground: View {
    var body: some View {
        ZStack {
            Color.auraBg
            RadialGradient(colors: [Color.auraPrimary.opacity(0.10), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 480)
            RadialGradient(colors: [Color.auraViolet.opacity(0.10), .clear],
                           center: .bottomLeading, startRadius: 8, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass surfaces

/// Frosted dark card background for List/Form rows.
struct GlassRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.auraOutline.opacity(0.6), lineWidth: 1)
            )
            .padding(.vertical, 3)
    }
}

extension View {
    /// Solid surface card with a hairline outline (AuraCast panel).
    func aeroGlass(cornerRadius: CGFloat = 24) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.auraSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.auraOutline.opacity(0.6), lineWidth: 1)
            )
    }

    /// Aura backdrop behind a scrollable screen, hiding the opaque system list
    /// background so it shows through.
    func aeroScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AeroBackground())
    }

    /// Uppercase, letter-spaced micro-label (AuraCast section headers).
    func auraLabel() -> some View {
        self
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .kerning(1.2)
            .foregroundStyle(Color.auraMuted)
    }
}

// MARK: - Buttons

/// The signature bright-cyan glowing action button ("Connect / Send to badge").
struct AeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color(hex: 0x06181B))
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.auraCyanBright, Color(hex: 0x00D6E2)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Color.auraCyanBright.opacity(configuration.isPressed ? 0.3 : 0.55),
                    radius: 16, y: 0)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
