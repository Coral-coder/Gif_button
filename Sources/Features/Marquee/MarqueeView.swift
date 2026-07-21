import SwiftUI
import UIKit

enum MarqueeMode: String, CaseIterable, Identifiable {
    case still = "Still"
    case scroll = "Scroll"
    var id: String { rawValue }
}

/// Editable state for the Text tab. Owned above the TabView so it survives tab
/// switches.
final class MarqueeDraft: ObservableObject {
    @Published var text = ""
    @Published var textColor = Color.white
    @Published var background = Color.black
    @Published var mode: MarqueeMode = .still
}

struct MarqueeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var queue: SendQueue
    @EnvironmentObject private var draft: MarqueeDraft

    @State private var statusText: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Type something…", text: $draft.text, axis: .vertical)
                        .lineLimit(1...3)
                    ColorPicker("Text color", selection: $draft.textColor, supportsOpacity: false)
                    ColorPicker("Background", selection: $draft.background, supportsOpacity: false)
                    Picker("Mode", selection: $draft.mode) {
                        ForEach(MarqueeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
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
                        Label("Badge not connected — this will be queued and sent when it connects.",
                              systemImage: "tray.and.arrow.down")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let statusText {
                    Section { Text(statusText).font(.callout).foregroundStyle(.secondary) }
                }

                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        Label(bluetooth.isConnected ? "Send text to badge" : "Add text to queue",
                              systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Text")
        }
    }

    private var preview: UIImage {
        ImageEncoder.renderText(draft.text.isEmpty ? "Preview" : draft.text,
                                side: min(settings.displaySide, 368),
                                color: UIColor(draft.textColor),
                                background: UIColor(draft.background))
    }

    private func send() async {
        isWorking = true
        defer { isWorking = false }
        let side = settings.displaySide
        let quality = settings.jpegQuality
        let content = draft.text
        let fg = UIColor(draft.textColor)
        let bg = UIColor(draft.background)
        let mode = draft.mode
        do {
            statusText = "Encoding…"
            let built = try await Task.detached(priority: .userInitiated) { () throws -> (packets: [Data], thumb: Data?) in
                let rendered = ImageEncoder.renderText(content, side: side, color: fg, background: bg)
                let image = try ImageEncoder.encodeStill(rendered, side: side, quality: quality)
                let packets: [Data]
                switch mode {
                case .still:
                    packets = EGoodsProtocol.packStillImage(image)
                case .scroll:
                    // Badge's dedicated marquee command. `display`/`number`
                    // semantics are best-effort until verified on hardware.
                    let container = EGoodsProtocol.animationContainer(
                        frames: [image.jpeg], name: "text", frameDelayMs: 100,
                        width: image.width, height: image.height)
                    var p: [Data] = []
                    if let info = EGoodsProtocol.marqueeInfo(width: image.width, height: image.height,
                                                             display: 1, number: 1) {
                        p.append(info)
                    }
                    p.append(contentsOf: EGoodsProtocol.marqueeData(container: container))
                    packets = p
                }
                return (packets, image.jpeg)
            }.value

            let preview = built.thumb.flatMap(UIImage.init(data:))
            queue.enqueue(SendJob(label: content.isEmpty ? "Text" : content, preview: preview, packets: built.packets))
            statusText = bluetooth.isConnected
                ? "Sending…"
                : "Added to queue — will send when the badge connects."
        } catch {
            statusText = error.localizedDescription
        }
    }
}
