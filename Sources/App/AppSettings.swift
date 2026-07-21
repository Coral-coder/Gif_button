import Foundation

/// User-configurable settings, persisted in `UserDefaults`.
///
/// API keys for Giphy/Tenor are *client* keys (meant to ship in apps), so
/// `UserDefaults` is acceptable. If you prefer, move them to the Keychain later.
final class AppSettings: ObservableObject {
    @Published var giphyAPIKey: String { didSet { defaults.set(giphyAPIKey, forKey: Keys.giphy) } }
    @Published var tenorAPIKey: String { didSet { defaults.set(tenorAPIKey, forKey: Keys.tenor) } }

    /// The badge's display resolution. The DZBJ "e-Goods" badge is 368×368; the
    /// stock app defaults to that. Adjust here if your model differs.
    @Published var displaySide: Int { didSet { defaults.set(displaySide, forKey: Keys.side) } }

    /// JPEG compression quality (0…1) used when encoding frames for the badge.
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Keys.quality) } }

    /// Reconnect to the last-used badge automatically when Bluetooth is ready.
    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: Keys.autoConnect) } }

    /// Maximum number of items held in the send queue. Oldest are dropped first.
    @Published var maxQueueSize: Int { didSet { defaults.set(maxQueueSize, forKey: Keys.maxQueue) } }

    /// Blank the badge (upload a black frame) before draining the queue.
    @Published var clearBeforeSend: Bool { didSet { defaults.set(clearBeforeSend, forKey: Keys.clearFirst) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let giphy = "giphyAPIKey"
        static let tenor = "tenorAPIKey"
        static let side = "displaySide"
        static let quality = "jpegQuality"
        static let autoConnect = "autoConnect"
        static let maxQueue = "maxQueueSize"
        static let clearFirst = "clearBeforeSend"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // didSet is not triggered by assignments inside init, so no spurious writes.
        self.giphyAPIKey = defaults.string(forKey: Keys.giphy) ?? ""
        self.tenorAPIKey = defaults.string(forKey: Keys.tenor) ?? ""
        let side = defaults.integer(forKey: Keys.side)
        self.displaySide = side == 0 ? 368 : side
        let quality = defaults.double(forKey: Keys.quality)
        self.jpegQuality = quality == 0 ? 0.8 : quality
        // Bool/Int defaults: use object(forKey:) so an unset key falls back sensibly.
        self.autoConnect = (defaults.object(forKey: Keys.autoConnect) as? Bool) ?? true
        let maxQ = defaults.integer(forKey: Keys.maxQueue)
        self.maxQueueSize = maxQ == 0 ? 8 : maxQ
        self.clearBeforeSend = (defaults.object(forKey: Keys.clearFirst) as? Bool) ?? false
    }
}
