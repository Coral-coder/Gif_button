import UIKit
import UniformTypeIdentifiers

/// Minimal share sheet: grabs the shared GIF/image/URL, writes it to the shared
/// App Group inbox, and completes. The main app picks it up on next launch (or
/// when it becomes active) and shows it in the send screen.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.98)

        label.text = "Saving to GifCast…"
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task { await handleShare() }
    }

    private func handleShare() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var saved = 0
        for item in items {
            for provider in item.attachments ?? [] {
                if await save(provider) { saved += 1 }
            }
        }
        await MainActor.run {
            label.text = saved > 0 ? "Saved to GifCast" : "Nothing to send"
        }
        // Brief confirmation, then dismiss.
        try? await Task.sleep(nanoseconds: 500_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Returns true if something was saved.
    private func save(_ provider: NSItemProvider) async -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier),
           let data = await loadData(provider, UTType.gif.identifier) {
            SharedInbox.save(data: data, ext: "gif")
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider, UTType.image.identifier) {
            SharedInbox.save(data: data, ext: "img")
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider) {
            SharedInbox.save(url: url)
            return true
        }
        return false
    }

    private func loadData(_ provider: NSItemProvider, _ typeID: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }
}
