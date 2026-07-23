import Combine
import UIKit

/// One queued transfer: a device-agnostic payload plus a thumbnail and label for
/// the queue UI. The payload is encoded to wire packets by the *connected*
/// badge's adapter at drain time — never before — so a job queued while
/// disconnected (or before we know which badge we'll talk to) is always encoded
/// for the protocol the badge actually speaks. This is what lets one queue serve
/// multiple badge families (DZBJ, BeamBox, …) correctly.
struct SendJob: Identifiable {
    let id = UUID()
    let label: String
    let preview: UIImage?
    let payload: BadgePayload
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

    /// The representative still JPEG for a payload (first frame for animations) —
    /// used by badges that take a single background image (Jieli custom dial bg).
    private static func firstImageJPEG(_ payload: BadgePayload) -> Data {
        switch payload {
        case .still(let image): return image.jpeg
        case .animation(let anim): return anim.frames.first?.jpeg ?? Data()
        }
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
            // Encode the blank frame with the CONNECTED badge's adapter (there is
            // no device-side delete command — "clear" means uploading a black
            // frame). Never hardcode a protocol here.
            if let blank = try? bluetooth.encodePackets(.still(ImageEncoder.black(side: settings.displaySide))) {
                try? await bluetooth.transmit(blank)
            }
        }

        while bluetooth.isConnected, let job = jobs.first {
            currentLabel = job.label
            do {
                if bluetooth.usesInteractiveUpload {
                    // Jieli (AE00: E87/L8/N88) — interactive custom-dial-bg upload.
                    // The badge wants raw pixels; convert the payload's image to
                    // an RGB565 background (side confirmed on-device; 240 default).
                    let jpeg = Self.firstImageJPEG(job.payload)
                    let bytes = ImageEncoder.rgb565(fromJPEG: jpeg, side: 240)
                    try await bluetooth.uploadJieliBytes(bytes)
                } else {
                    // Encode now, via the auto-detected adapter for the badge we're
                    // actually connected to.
                    let packets = try bluetooth.encodePackets(job.payload)
                    try await bluetooth.transmit(packets)
                }
                jobs.removeFirst()
            } catch let error as BadgeError {
                // Unsupported badge / encoding problem: surface it and stop so we
                // don't spin. Remaining jobs stay queued for a supported badge.
                bluetooth.lastMessage = error.errorDescription
                break
            } catch {
                // Transient (e.g. disconnect mid-send): leave queued, retry later.
                break
            }
        }
    }
}
