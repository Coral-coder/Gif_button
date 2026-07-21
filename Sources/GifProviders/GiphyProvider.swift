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

    func trending(cursor: String?, limit: Int) async throws -> GifPage {
        try await fetch(path: "trending", query: nil, cursor: cursor, limit: limit)
    }

    func search(query: String, cursor: String?, limit: Int) async throws -> GifPage {
        try await fetch(path: "search", query: query, cursor: cursor, limit: limit)
    }

    private func fetch(path: String, query: String?, cursor: String?, limit: Int) async throws -> GifPage {
        guard !apiKey.isEmpty else { throw HTTPError.missingAPIKey("Giphy") }
        let offset = Int(cursor ?? "") ?? 0
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/\(path)")!
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: "pg-13"),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        components.queryItems = items
        let response = try await client.getJSON(GiphyResponse.self, url: components.url!)
        let gifs = response.data.compactMap { $0.asGifItem }

        // Next cursor: advance the offset while more results remain.
        let advanced = offset + (response.pagination?.count ?? gifs.count)
        let total = response.pagination?.totalCount ?? 0
        let next = (!gifs.isEmpty && advanced < total) ? String(advanced) : nil
        return GifPage(items: gifs, nextCursor: next)
    }
}

// MARK: - Wire types

private struct GiphyResponse: Decodable {
    let data: [GiphyGif]
    let pagination: GiphyPagination?
}

private struct GiphyPagination: Decodable {
    let totalCount: Int?
    let count: Int?
    let offset: Int?

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case count
        case offset
    }
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
