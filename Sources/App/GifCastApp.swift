import SwiftUI

/// Owns the shared object graph so dependencies (queue needs Bluetooth +
/// settings) can be wired at startup, then injected into the view tree. Held by
/// a single @StateObject so nothing is recreated on tab switches.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let bluetooth: BluetoothManager
    let queue: SendQueue
    let search: SearchViewModel
    let imports: ImportStore

    init() {
        let settings = AppSettings()
        let bluetooth = BluetoothManager(settings: settings)
        self.settings = settings
        self.bluetooth = bluetooth
        self.queue = SendQueue(bluetooth: bluetooth, settings: settings)
        self.search = SearchViewModel()
        self.imports = ImportStore()
    }
}

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
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model.settings)
                .environmentObject(model.bluetooth)
                .environmentObject(model.queue)
                .environmentObject(model.search)
                .environmentObject(model.imports)
        }
    }
}
