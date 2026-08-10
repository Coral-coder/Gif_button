import Foundation

/// Tiny async wrapper around URLSession. Deliberately dependency-free.
struct HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func getJSON<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    /// Downloads raw bytes (used to fetch the chosen GIF before encoding it).
    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return data
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode)
        }
    }
}

enum HTTPError: LocalizedError {
    case invalidResponse
    case status(Int)
    case decoding(Error)
    case missingAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .status(let code):
            return "Request failed (HTTP \(code))."
        case .decoding:
            return "Couldn't read the response from the service."
        case .missingAPIKey(let name):
            return "Add your \(name) API key in Settings first."
        }
    }
}
