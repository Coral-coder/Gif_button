import Foundation

/// Klipy API — a free, Tenor-compatible GIF service (built by the ex-Tenor
/// team). Get a key at https://klipy.com/developers.
///
/// The app key is placed in the path: `/api/v1/{appKey}/gifs/{search|trending}`.
/// Decoding is defensive (Klipy's public docs are gated) so an unexpected shape
/// yields no results rather than a crash.
struct KlipyProvider: GifProvider {
    let source: GifSource = .klipy
    let apiKey: String
    let client: HTTPClient
    /// Klipy wants a stable per-user id for its content filtering/ads.
    private let customerID = "gifcast-user"

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
        guard !apiKey.isEmpty else { throw HTTPError.missingAPIKey("Klipy") }
        let page = Int(cursor ?? "") ?? 1
        var components = URLComponents(string: "https://api.klipy.com/api/v1/\(apiKey)/gifs/\(path)")!
        var items = [
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "customer_id", value: customerID),
            URLQueryItem(name: "content_filter", value: "medium"),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        components.queryItems = items

        let response = try await client.getJSON(KlipyResponse.self, url: components.url!)
        let gifs = response.data.data.compactMap { $0.asGifItem }
        let next = (response.data.hasNext == true && !gifs.isEmpty) ? String(page + 1) : nil
        return GifPage(items: gifs, nextCursor: next)
    }
}

// MARK: - Wire types

private struct KlipyResponse: Decodable {
    let data: KlipyData
}

private struct KlipyData: Decodable {
    let data: [KlipyItem]
    let hasNext: Bool?

    enum CodingKeys: String, CodingKey {
        case data
        case hasNext = "has_next"
    }
}

private struct KlipyItem: Decodable {
    let id: String
    let title: String?
    let file: KlipyFile?

    enum CodingKeys: String, CodingKey { case id, title, file }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .id) {
            id = String(i)
        } else {
            id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        }
        title = try? c.decode(String.self, forKey: .title)
        file = try? c.decode(KlipyFile.self, forKey: .file)
    }

    var asGifItem: GifItem? {
        let full = file?.md?.gif ?? file?.hd?.gif ?? file?.sm?.gif
        let preview = file?.sm?.gif ?? file?.xs?.gif ?? full
        guard let f = full, let fullURL = URL(string: f.url),
              let p = preview, let previewURL = URL(string: p.url) else { return nil }
        return GifItem(
            id: id,
            title: (title?.isEmpty == false ? title! : "GIF"),
            previewURL: previewURL,
            fullURL: fullURL,
            width: f.width ?? 0,
            height: f.height ?? 0,
            source: .klipy
        )
    }
}

private struct KlipyFile: Decodable {
    let hd: KlipyVariant?
    let md: KlipyVariant?
    let sm: KlipyVariant?
    let xs: KlipyVariant?
}

private struct KlipyVariant: Decodable {
    let gif: KlipyMedia?
}

private struct KlipyMedia: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}
