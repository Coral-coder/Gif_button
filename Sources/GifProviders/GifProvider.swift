import Foundation

/// One page of results plus an opaque cursor for the next page (nil = no more).
/// The cursor format is provider-specific (Giphy: numeric offset; Tenor: `pos`).
struct GifPage {
    let items: [GifItem]
    let nextCursor: String?
}

/// Abstraction over a GIF search backend (Giphy, Tenor, …).
protocol GifProvider {
    var source: GifSource { get }
    func trending(cursor: String?, limit: Int) async throws -> GifPage
    func search(query: String, cursor: String?, limit: Int) async throws -> GifPage
}
