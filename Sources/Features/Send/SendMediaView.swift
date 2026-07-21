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
/// Detects GIF vs still from the bytes and offers animation when possible.
struct SendMediaView: View {
    let pending: PendingSend

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bluetooth: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    @State private var statusText: String?
    @State private var isWorking = false
    @State private var sendAsAnimation = true
    @State private var localData: Data?
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
                    Label("No badge connected — open the Badge tab to connect.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }

                if bluetooth.status == .sending {
                    ProgressView(value: bluetooth.uploadProgress).padding(.horizontal)
                }

                if let statusText {
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }

                Button {
                    Task { await send() }
                } label: {
                    Label("Send to badge", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || !bluetooth.isConnected)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear(perform: analyzeLocal)
        }
    }

    @ViewBuilder private var preview: some View {
        if let url = pending.previewURL {
            GifThumbnail(url: url)
        } else if let data = localData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Color.gray.opacity(0.15).overlay(ProgressView())
        }
    }

    private func analyzeLocal() {
        guard case .data(let data) = pending.source else { return }
        localData = data
        canAnimate = Self.isGIF(data)
        sendAsAnimation = canAnimate
    }

    private func send() async {
        isWorking = true
        defer { isWorking = false }
        let side = settings.displaySide
        let quality = settings.jpegQuality
        do {
            statusText = "Preparing…"
            let data = try await resolveData()
            let animate = sendAsAnimation && Self.isGIF(data)
            statusText = "Encoding…"

            if animate {
                let animation = try await Task.detached(priority: .userInitiated) {
                    try ImageEncoder.encodeAnimation(fromGIFData: data, side: side, quality: quality)
                }.value
                statusText = "Sending \(animation.frames.count) frames…"
                try bluetooth.sendAnimation(animation)
            } else {
                let image = try await Task.detached(priority: .userInitiated) { () throws -> EncodedImage in
                    guard let ui = UIImage(data: data) else { throw BadgeError.encodingFailed }
                    return try ImageEncoder.encodeStill(ui, side: side, quality: quality)
                }.value
                statusText = "Sending…"
                try bluetooth.sendStillImage(image)
            }
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
