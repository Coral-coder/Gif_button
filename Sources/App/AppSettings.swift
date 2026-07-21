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

    private let defaults: UserDefaults

    private enum Keys {
        static let giphy = "giphyAPIKey"
        static let tenor = "tenorAPIKey"
        static let side = "displaySide"
        static let quality = "jpegQuality"
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
    }
}
