import SwiftUI
import UIKit

/// Where a to-be-sent piece of media comes from.
enum MediaSource {
    case remote(URL)   // downloaded on send (Giphy/Tenor result, or pasted URL)
    case data(Data)    // already-in-hand bytes (photo library)
}

/// A single media item queued for preview + send. Identifiable so it can drive
/// a `.sheet(item:)`.
struct PendingSend: Identifiable {
    let id = UUID()
    let title: String
    let previewURL: URL?
    let source: MediaSource
}

/// Unified preview-and-send screen for every source (GIF search, photos, URL).
/// Detects GIF vs still from the bytes, encodes, and adds the result to the send
/// queue (which delivers it to the badge now, or when it next connects).
struct SendMediaView: View {
    let pending: PendingSend

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var queue: SendQueue
    @Environment(\.dismiss) private var dismiss

    @State private var statusText: String?
    @State private var isWorking = false
    @State private var sendAsAnimation = true
    @State private var previewData: Data?
    @State private var canAnimate = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                Text(pending.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)

                if canAnimate {
                    Toggle("Send as animation", isOn: $sendAsAnimation)
                        .padding(.horizontal)
                }

                if !bluetooth.isConnected {
                    Label("Badge not connected — this will be queued and sent when it connects.",
                          systemImage: "tray.and.arrow.down")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }

                if let statusText {
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }

                Button {
                    Task { await addToQueue() }
                } label: {
                    Label(bluetooth.isConnected ? "Send to badge" : "Add to queue",
                          systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AeroButtonStyle())
                .disabled(isWorking)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .background(AeroBackground())
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await loadPreview() }
        }
    }

    @ViewBuilder private var preview: some View {
        if let data = previewData {
            if Self.isGIF(data) {
                AnimatedGIFView(data: data)
            } else if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.gray.opacity(0.15).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        } else {
            Color.gray.opacity(0.15).overlay(ProgressView())
        }
    }

    /// Load bytes for the animated preview: local data directly, or the small
    /// preview URL for remote sources (the full-size GIF is fetched on send).
    private func loadPreview() async {
        guard previewData == nil else { return }
        switch pending.source {
        case .data(let data):
            previewData = data
        case .remote(let url):
            previewData = try? await HTTPClient().data(from: pending.previewURL ?? url)
        }
        if let data = previewData {
            canAnimate = Self.isGIF(data)
            if !canAnimate { sendAsAnimation = false }
        }
    }

    private func addToQueue() async {
        isWorking = true
        defer { isWorking = false }
        let side = settings.displaySide
        let quality = settings.jpegQuality
        let label = pending.title
        do {
            statusText = "Preparing…"
            let data = try await resolveData()
            let animate = sendAsAnimation && Self.isGIF(data)

            let built = try await Task.detached(priority: .userInitiated) { () throws -> (packets: [Data], thumb: Data?) in
                let packets: [Data]
                if animate {
                    let animation = try ImageEncoder.encodeAnimation(fromGIFData: data, side: side, quality: quality)
                    packets = EGoodsProtocol.packAnimation(animation)
                } else {
                    guard let ui = UIImage(data: data) else { throw BadgeError.encodingFailed }
                    let image = try ImageEncoder.encodeStill(ui, side: side, quality: quality)
                    packets = EGoodsProtocol.packStillImage(image)
                }
                let thumb = ImageEncoder.thumbnail(from: data)?.jpegData(compressionQuality: 0.7)
                return (packets, thumb)
            }.value

            let preview = built.thumb.flatMap(UIImage.init(data:))
            queue.enqueue(SendJob(label: label, preview: preview, packets: built.packets))

            statusText = bluetooth.isConnected
                ? "Sending to badge…"
                : "Added to queue — will send when the badge connects."
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func resolveData() async throws -> Data {
        switch pending.source {
        case .data(let data):
            return data
        case .remote(let url):
            statusText = "Downloading…"
            return try await HTTPClient().data(from: url)
        }
    }

    /// GIF magic number: "GIF8" (both GIF87a and GIF89a).
    static func isGIF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == 0x47 &&
               data[data.startIndex + 1] == 0x49 &&
               data[data.startIndex + 2] == 0x46 &&
               data[data.startIndex + 3] == 0x38
    }
}
