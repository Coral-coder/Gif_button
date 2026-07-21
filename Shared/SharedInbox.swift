import Foundation

/// A tiny hand-off between the Share Extension and the main app via the shared
/// App Group container. The extension writes files here; the app drains them.
enum SharedInbox {
    /// Must match the App Group id in both targets' entitlements.
    static let appGroup = "group.com.coralcoder.gifcast"
    private static let folder = "Inbox"

    enum Item {
        case data(Data)
        case url(URL)
    }

    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(folder, isDirectory: true)
    }

    private static func ensureDirectory() -> URL? {
        guard let dir = directory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Save shared image/GIF bytes. `ext` is only a hint; the app detects the
    /// real type from the bytes.
    static func save(data: Data, ext: String) {
        guard let dir = ensureDirectory() else { return }
        let name = "\(timestampPrefix())-\(UUID().uuidString).\(ext)"
        try? data.write(to: dir.appendingPathComponent(name))
    }

    /// Save a shared web URL (the app downloads it later).
    static func save(url: URL) {
        guard let dir = ensureDirectory() else { return }
        let name = "\(timestampPrefix())-\(UUID().uuidString).url"
        try? url.absoluteString.data(using: .utf8)?.write(to: dir.appendingPathComponent(name))
    }

    /// Read and delete everything waiting, oldest first.
    static func drain() -> [Item] {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }

        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var items: [Item] = []
        for file in sorted {
            defer { try? FileManager.default.removeItem(at: file) }
            if file.pathExtension == "url" {
                if let data = try? Data(contentsOf: file),
                   let string = String(data: data, encoding: .utf8),
                   let url = URL(string: string) {
                    items.append(.url(url))
                }
            } else if let data = try? Data(contentsOf: file) {
                items.append(.data(data))
            }
        }
        return items
    }

    // Sortable, second-resolution prefix so drain() returns items in share order.
    private static func timestampPrefix() -> String {
        String(format: "%015.0f", Date().timeIntervalSince1970 * 1000)
    }
}
