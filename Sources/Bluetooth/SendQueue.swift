import Combine
import UIKit

/// One queued transfer: pre-encoded packets plus a thumbnail and label for the
/// queue UI. Encoding happens when you tap Send, so a job is ready to fire the
/// moment the badge connects — even if you queued it while disconnected.
struct SendJob: Identifiable {
    let id = UUID()
    let label: String
    let preview: UIImage?
    let packets: [Data]
}

/// Holds pending transfers and drains them to the badge one at a time. Survives
/// disconnection (jobs wait), auto-drains when the badge becomes ready, caps its
/// size, and can blank the badge before writing (there is no device-side delete
/// command — see docs/PROTOCOL.md — so "clear" means uploading a black frame).
@MainActor
final class SendQueue: ObservableObject {
    @Published private(set) var jobs: [SendJob] = []
    @Published private(set) var isDraining = false
    @Published private(set) var currentLabel: String?

    private let bluetooth: BluetoothManager
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    init(bluetooth: BluetoothManager, settings: AppSettings) {
        self.bluetooth = bluetooth
        self.settings = settings
        // Drain automatically whenever the badge becomes ready.
        bluetooth.$isReady
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] ready in
                guard ready else { return }
                Task { @MainActor in self?.drainIfPossible() }
            }
            .store(in: &cancellables)
    }

    func enqueue(_ job: SendJob) {
        jobs.append(job)
        let cap = max(1, settings.maxQueueSize)
        if jobs.count > cap { jobs.removeFirst(jobs.count - cap) }
        drainIfPossible()
    }

    func remove(_ job: SendJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clear() {
        jobs.removeAll()
    }

    func drainIfPossible() {
        guard !isDraining, bluetooth.isConnected, !jobs.isEmpty else { return }
        Task { await drain() }
    }

    private func drain() async {
        isDraining = true
        defer { isDraining = false; currentLabel = nil }

        if settings.clearBeforeSend {
            currentLabel = "Clearing badge…"
            let blank = EGoodsProtocol.packStillImage(ImageEncoder.black(side: settings.displaySide))
            try? await bluetooth.transmit(blank)
        }

        while bluetooth.isConnected, let job = jobs.first {
            currentLabel = job.label
            do {
                try await bluetooth.transmit(job.packets)
                jobs.removeFirst()
            } catch {
                // Leave this and remaining jobs queued; retry on reconnect.
                break
            }
        }
    }
}
