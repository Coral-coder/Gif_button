import SwiftUI

/// GifCast — a privacy-respecting replacement for the stock badge app.
///
/// Design principles:
/// - No analytics, no ad SDKs, no third-party network calls. The only hosts the
///   app ever talks to are the GIF services you explicitly search (Giphy/Tenor),
///   plus the CDN that hosts a GIF you choose to download. Everything else is
///   on-device or a direct Bluetooth link to your badge.
/// - The Bluetooth protocol is isolated in one place (`EGoodsProtocol`) so the
///   reverse-engineered details are easy to audit and adjust.
@main
struct GifCastApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var bluetooth = BluetoothManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(bluetooth)
        }
    }
}
