import SwiftUI
import UIKit

struct GifDetailView: View {
    let item: GifItem

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bluetooth: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    @State private var statusText: String?
    @State private var isWorking = false
    @State private var sendAsAnimation = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GifThumbnail(url: item.previewURL)
                    .frame(height: 220)
                    .padding(.horizontal)

                Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)

                Toggle("Send as animation", isOn: $sendAsAnimation)
                    .padding(.horizontal)
                    .help("Off sends only the first frame as a still image.")

                if !bluetooth.isConnected {
                    Label("No badge connected — open the Badge tab to connect.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if bluetooth.status == .sending {
                    ProgressView(value: bluetooth.uploadProgress)
                        .padding(.horizontal)
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
            .navigationTitle("Send GIF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func send() async {
        isWorking = true
        defer { isWorking = false }
        do {
            statusText = "Downloading…"
            let data = try await HTTPClient().data(from: item.fullURL)

            let side = settings.displaySide
            let quality = settings.jpegQuality
            statusText = "Encoding…"

            if sendAsAnimation {
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
}
