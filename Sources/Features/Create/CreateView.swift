import SwiftUI
import UIKit

/// "Create" tab — generate badge images on-device (no GIF needed): scrolling-free
/// styled Text, a QR code, or a color/gradient fill. Each mode renders a square
/// image at the badge's native resolution, previews it, and hands it to the same
/// send/queue pipeline as GIFs. Inspired by the AuraCast creative modes, adapted
/// for these JPEG image badges.
struct CreateView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var queue: SendQueue

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text"
        case qr = "QR"
        case color = "Color"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .text: return "textformat"
            case .qr: return "qrcode"
            case .color: return "paintpalette"
            }
        }
    }

    @State private var mode: Mode = .text
    @State private var pending: PendingSend?
    @State private var showQueue = false

    // Text
    @State private var text = "HELLO"
    @State private var textColor = Color.white
    @State private var textBackground = Color.black

    // QR
    @State private var qrText = "https://"
    @State private var qrColor = Color.black
    @State private var qrBackground = Color.white

    // Color / gradient
    @State private var useGradient = true
    @State private var colorStart = Color(red: 0, green: 0.86, blue: 0.91)
    @State private var colorEnd = Color(red: 0.5, green: 0.2, blue: 0.9)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Label(m.rawValue, systemImage: m.icon).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    BadgePreview(data: previewData, size: 240)
                        .padding(.top, 4)

                    controls
                        .padding(.horizontal)

                    Button {
                        if let data = previewData {
                            pending = PendingSend(title: sendTitle, previewURL: nil, source: .data(data))
                        }
                    } label: {
                        Label("Preview & send", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AeroButtonStyle())
                    .padding(.horizontal)
                    .disabled(previewData == nil)

                    Spacer(minLength: 12)
                }
                .padding(.top)
            }
            .aeroScreen()
            .navigationTitle("Create")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showQueue = true } label: {
                        Image(systemName: (queue.jobs.isEmpty && !queue.isDraining) ? "tray" : "tray.full")
                    }
                }
            }
            .sheet(item: $pending) { SendMediaView(pending: $0) }
            .sheet(isPresented: $showQueue) { QueueView() }
        }
    }

    @ViewBuilder private var controls: some View {
        switch mode {
        case .text:
            VStack(spacing: 12) {
                TextField("Text", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                ColorPicker("Text color", selection: $textColor)
                ColorPicker("Background", selection: $textBackground)
            }
        case .qr:
            VStack(spacing: 12) {
                TextField("Text or URL", text: $qrText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ColorPicker("Code color", selection: $qrColor)
                ColorPicker("Background", selection: $qrBackground)
            }
        case .color:
            VStack(spacing: 12) {
                Toggle("Gradient", isOn: $useGradient)
                ColorPicker(useGradient ? "From" : "Color", selection: $colorStart)
                if useGradient {
                    ColorPicker("To", selection: $colorEnd)
                }
            }
        }
    }

    private var sendTitle: String {
        switch mode {
        case .text: return text.isEmpty ? "Text" : String(text.prefix(20))
        case .qr: return "QR: \(qrText.prefix(24))"
        case .color: return useGradient ? "Gradient" : "Solid color"
        }
    }

    /// Render the current mode to badge-sized JPEG data for preview + send.
    private var previewData: Data? {
        let side = settings.displaySide
        let image: UIImage
        switch mode {
        case .text:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            image = ImageEncoder.renderText(text, side: side,
                                            color: UIColor(textColor), background: UIColor(textBackground))
        case .qr:
            guard !qrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            image = ImageEncoder.renderQR(qrText, side: side,
                                          color: UIColor(qrColor), background: UIColor(qrBackground))
        case .color:
            image = useGradient
                ? ImageEncoder.renderGradient(from: UIColor(colorStart), to: UIColor(colorEnd), side: side)
                : ImageEncoder.renderGradient(from: UIColor(colorStart), to: UIColor(colorStart), side: side)
        }
        return ImageEncoder.jpegData(image)
    }
}
