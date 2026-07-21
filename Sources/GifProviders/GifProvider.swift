import Foundation

/// Abstraction over a GIF search backend (Giphy, Tenor, …).
protocol GifProvider {
    var source: GifSource { get }
    func trending(limit: Int) async throws -> [GifItem]
    func search(query: String, limit: Int) async throws -> [GifItem]
}
