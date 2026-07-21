import SwiftUI
import UIKit

struct MarqueeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bluetooth: BluetoothManager

    @State private var text = ""
    @State private var textColor = Color.white
    @State private var background = Color.black
    @State private var mode: Mode = .still
    @State private var statusText: String?
    @State private var isWorking = false

    enum Mode: String, CaseIterable, Identifiable {
        case still = "Still"
        case scroll = "Scroll"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Type something…", text: $text, axis: .vertical)
                        .lineLimit(1...3)
                    ColorPicker("Text color", selection: $textColor, supportsOpacity: false)
                    ColorPicker("Background", selection: $background, supportsOpacity: false)
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    // Live preview of what gets rasterized to the badge.
                    Image(uiImage: preview)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } header: {
                    Text("Preview")
                }

                if !bluetooth.isConnected {
                    Section {
                        Label("No badge connected — open the Badge tab first.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                if let statusText {
                    Section { Text(statusText).font(.callout).foregroundStyle(.secondary) }
                }

                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        Label("Send text to badge", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || text.trimmingCharacters(in: .whitespaces).isEmpty || !bluetooth.isConnected)
                }
            }
            .navigationTitle("Text")
        }
    }

    private var preview: UIImage {
        ImageEncoder.renderText(text.isEmpty ? "Preview" : text,
                                side: min(settings.displaySide, 368),
                                color: UIColor(textColor),
                                background: UIColor(background))
    }

    private func send() async {
        isWorking = true
        defer { isWorking = false }
        let side = settings.displaySide
        let quality = settings.jpegQuality
        let content = text
        let fg = UIColor(textColor)
        let bg = UIColor(background)
        do {
            statusText = "Encoding…"
            let image = try await Task.detached(priority: .userInitiated) { () throws -> EncodedImage in
                let rendered = ImageEncoder.renderText(content, side: side, color: fg, background: bg)
                return try ImageEncoder.encodeStill(rendered, side: side, quality: quality)
            }.value

            statusText = "Sending…"
            switch mode {
            case .still:
                try bluetooth.sendStillImage(image)
            case .scroll:
                // Uses the badge's dedicated marquee command. `display`/`number`
                // semantics are best-effort until verified on hardware.
                let container = EGoodsProtocol.animationContainer(
                    frames: [image.jpeg], name: "text", frameDelayMs: 100,
                    width: image.width, height: image.height)
                try bluetooth.sendMarquee(container: container, width: image.width,
                                          height: image.height, display: 1, number: 1)
            }
        } catch {
            statusText = error.localizedDescription
        }
    }
}
