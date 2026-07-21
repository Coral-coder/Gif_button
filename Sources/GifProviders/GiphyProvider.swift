import Foundation

/// Giphy API v1. Get a free key at https://developers.giphy.com.
struct GiphyProvider: GifProvider {
    let source: GifSource = .giphy
    let apiKey: String
    let client: HTTPClient

    init(apiKey: String, client: HTTPClient = HTTPClient()) {
        self.apiKey = apiKey
        self.client = client
    }

    func trending(limit: Int) async throws -> [GifItem] {
        try await fetch(path: "trending", query: nil, limit: limit)
    }

    func search(query: String, limit: Int) async throws -> [GifItem] {
        try await fetch(path: "search", query: query, limit: limit)
    }

    private func fetch(path: String, query: String?, limit: Int) async throws -> [GifItem] {
        guard !apiKey.isEmpty else { throw HTTPError.missingAPIKey("Giphy") }
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/\(path)")!
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "rating", value: "pg-13"),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        components.queryItems = items
        let response = try await client.getJSON(GiphyResponse.self, url: components.url!)
        return response.data.compactMap { $0.asGifItem }
    }
}

// MARK: - Wire types

private struct GiphyResponse: Decodable {
    let data: [GiphyGif]
}

private struct GiphyGif: Decodable {
    let id: String
    let title: String?
    let images: GiphyImages

    var asGifItem: GifItem? {
        let preview = images.fixedWidth ?? images.original
        guard let previewString = preview?.url, let previewURL = URL(string: previewString),
              let fullString = images.original?.url, let fullURL = URL(string: fullString)
        else { return nil }
        return GifItem(
            id: id,
            title: (title?.isEmpty == false ? title! : "GIF"),
            previewURL: previewURL,
            fullURL: fullURL,
            width: Int(images.original?.width ?? "") ?? 0,
            height: Int(images.original?.height ?? "") ?? 0,
            source: .giphy
        )
    }
}

private struct GiphyImages: Decodable {
    let original: GiphyImage?
    let fixedWidth: GiphyImage?

    enum CodingKeys: String, CodingKey {
        case original
        case fixedWidth = "fixed_width"
    }
}

private struct GiphyImage: Decodable {
    let url: String?
    let width: String?   // Giphy returns dimensions as strings
    let height: String?
}
