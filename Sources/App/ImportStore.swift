import Foundation

/// Drains items shared into the app (via the Share Extension's App Group inbox)
/// and exposes them as `PendingSend`s for the send screen to present.
@MainActor
final class ImportStore: ObservableObject {
    @Published var pending: [PendingSend] = []

    func ingest() {
        for item in SharedInbox.drain() {
            switch item {
            case .data(let data):
                pending.append(PendingSend(title: "Shared GIF", previewURL: nil, source: .data(data)))
            case .url(let url):
                pending.append(PendingSend(title: "Shared link", previewURL: url, source: .remote(url)))
            }
        }
    }
}
