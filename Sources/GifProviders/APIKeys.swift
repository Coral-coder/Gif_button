import Foundation

/// Baked-in default API keys. These are compiled into the app so it can ship
/// working without typing keys into Settings. A key entered in the app's
/// Settings tab always overrides whatever is here.
///
/// Left empty on purpose so nothing secret lives in the repo. To enable a
/// source out of the box, paste a key between the quotes below and rebuild —
/// but remember this file is committed, so anything here becomes public if you
/// push it. (Prefer entering keys in Settings; they persist on-device.)
enum APIKeys {
    static let giphy = "owUAg8ndbHDkQ5CmneQRX15agJ3TGmbc"   // https://developers.giphy.com
    static let tenor = ""   // https://developers.google.com/tenor
    static let klipy = ""   // https://klipy.com/developers
}
