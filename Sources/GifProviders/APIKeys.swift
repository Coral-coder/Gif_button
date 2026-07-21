import Foundation

/// Baked-in default API keys so the app works out of the box without typing
/// keys into Settings. A key entered in Settings always overrides the baked one.
///
/// ⚠️ These are compiled into the app. If you push this repo publicly, anything
/// here is exposed — use free, rate-limited keys you don't mind sharing, or
/// leave them empty and enter keys in Settings instead.
///
/// To bake a key: paste it between the quotes below and rebuild.
enum APIKeys {
    static let giphy = ""   // e.g. "abcd1234..."  (https://developers.giphy.com)
    static let tenor = ""   // e.g. "AIza..."       (https://developers.google.com/tenor)
    static let klipy = ""   // e.g. "..."           (https://klipy.com/developers)
}
