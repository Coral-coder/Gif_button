import Foundation

/// Tenor API v2. Get a free key at https://developers.google.com/tenor.
struct TenorProvider: GifProvider {
    let source: GifSource = .tenor
    let apiKey: String
    let client: HTTPClient

    init(apiKey: String, client: HTTPClient = HTTPClient()) {
        self.apiKey = apiKey
        self.client = client
    }

    func trending(cursor: String?, limit: Int) async throws -> GifPage {
        // Tenor calls the trending feed "featured".
        try await fetch(path: "featured", query: nil, cursor: cursor, limit: limit)
    }

    func search(query: String, cursor: String?, limit: Int) async throws -> GifPage {
        try await fetch(path: "search", query: query, cursor: cursor, limit: limit)
    }

    private func fetch(path: String, query: String?, cursor: String?, limit: Int) async throws -> GifPage {
        guard !apiKey.isEmpty else { throw HTTPError.missingAPIKey("Tenor") }
        var components = URLComponents(string: "https://tenor.googleapis.com/v2/\(path)")!
        var items = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "media_filter", value: "gif,tinygif"),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "pos", value: cursor)) }
        components.queryItems = items
        let response = try await client.getJSON(TenorResponse.self, url: components.url!)
        let gifs = response.results.compactMap { $0.asGifItem }
        // Tenor returns "" (or omits) `next` when there are no more results.
        let next = (response.next?.isEmpty == false) ? response.next : nil
        return GifPage(items: gifs, nextCursor: gifs.isEmpty ? nil : next)
    }
}

// MARK: - Wire types

private struct TenorResponse: Decodable {
    let results: [TenorResult]
    let next: String?
}

private struct TenorResult: Decodable {
    let id: String
    let contentDescription: String?
    let mediaFormats: [String: TenorMedia]

    enum CodingKeys: String, CodingKey {
        case id
        case contentDescription = "content_description"
        case mediaFormats = "media_formats"
    }

    var asGifItem: GifItem? {
        guard let full = mediaFormats["gif"], let fullURL = URL(string: full.url) else { return nil }
        let preview = mediaFormats["tinygif"] ?? full
        let previewURL = URL(string: preview.url) ?? fullURL
        let dims = full.dims ?? []
        return GifItem(
            id: id,
            title: (contentDescription?.isEmpty == false ? contentDescription! : "GIF"),
            previewURL: previewURL,
            fullURL: fullURL,
            width: dims.count == 2 ? dims[0] : 0,
            height: dims.count == 2 ? dims[1] : 0,
            source: .tenor
        )
    }
}

private struct TenorMedia: Decodable {
    let url: String
    let dims: [Int]?
}
