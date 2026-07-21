import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Giphy API key", text: $settings.giphyAPIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Link("Get a free Giphy key", destination: URL(string: "https://developers.giphy.com/dashboard/")!)
                } header: {
                    Text("Giphy")
                } footer: {
                    Text("Create an app on Giphy's developer dashboard and paste its API key.")
                }
                .listRowBackground(GlassRow())

                Section {
                    SecureField("Tenor API key", text: $settings.tenorAPIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Link("Get a free Tenor key", destination: URL(string: "https://developers.google.com/tenor/guides/quickstart")!)
                } header: {
                    Text("Tenor")
                } footer: {
                    Text("Note: Google is shutting down the Tenor API on June 30, 2026.")
                }
                .listRowBackground(GlassRow())

                Section {
                    SecureField("Klipy API key", text: $settings.klipyAPIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Link("Get a free Klipy key", destination: URL(string: "https://klipy.com/developers")!)
                } header: {
                    Text("Klipy")
                } footer: {
                    Text("Free, Tenor-compatible GIF API. Leave blank to fall back to a baked-in key if one is set.")
                }
                .listRowBackground(GlassRow())

                Section("Badge display") {
                    Stepper("Resolution: \(settings.displaySide)×\(settings.displaySide)",
                            value: $settings.displaySide, in: 64...512, step: 8)
                    VStack(alignment: .leading) {
                        Text("JPEG quality: \(Int(settings.jpegQuality * 100))%")
                        Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                    }
                }
                .listRowBackground(GlassRow())

                Section {
                    Toggle("Auto-connect to last badge", isOn: $settings.autoConnect)
                    Stepper("Queue size: \(settings.maxQueueSize)",
                            value: $settings.maxQueueSize, in: 1...50)
                    Toggle("Clear badge before sending", isOn: $settings.clearBeforeSend)
                } header: {
                    Text("Sending")
                } footer: {
                    Text("Queued items are sent one at a time when the badge is connected; the oldest are dropped past the queue size. \"Clear\" uploads a black frame first — the badge has no delete command, so this blanks whatever is showing before the queue is written.")
                }
                .listRowBackground(GlassRow())

                Section {
                    Label("No analytics, no ad SDKs, no third-party trackers.",
                          systemImage: "hand.raised.fill")
                    Text("The app only contacts the GIF service you search (Giphy or Tenor) and the CDN hosting a GIF you choose to send. Your badge is reached directly over Bluetooth — nothing about it is uploaded anywhere.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Privacy")
                }
                .listRowBackground(GlassRow())

                Section {
                    LabeledContent("Version", value: "0.1.0")
                }
                .listRowBackground(GlassRow())
            }
            .navigationTitle("Settings")
            .aeroScreen()
        }
    }
}
