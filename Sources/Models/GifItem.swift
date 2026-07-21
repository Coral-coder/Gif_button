import Foundation

/// A single GIF result, normalized across providers.
struct GifItem: Identifiable, Hashable {
    let id: String
    let title: String
    /// Small looping preview, used for the grid/thumbnail.
    let previewURL: URL
    /// Full-resolution GIF, downloaded when sending to the badge.
    let fullURL: URL
    let width: Int
    let height: Int
    let source: GifSource
}

enum GifSource: String, Hashable, CaseIterable {
    case giphy
    case tenor
    case photoLibrary
    case url

    var displayName: String {
        switch self {
        case .giphy: return "Giphy"
        case .tenor: return "Tenor"
        case .photoLibrary: return "Photos"
        case .url: return "Link"
        }
    }
}
