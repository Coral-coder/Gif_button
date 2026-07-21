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

                Section {
                    SecureField("Tenor API key", text: $settings.tenorAPIKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Link("Get a free Tenor key", destination: URL(string: "https://developers.google.com/tenor/guides/quickstart")!)
                } header: {
                    Text("Tenor")
                }

                Section("Badge display") {
                    Stepper("Resolution: \(settings.displaySide)×\(settings.displaySide)",
                            value: $settings.displaySide, in: 64...512, step: 8)
                    VStack(alignment: .leading) {
                        Text("JPEG quality: \(Int(settings.jpegQuality * 100))%")
                        Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                    }
                }

                Section {
                    Label("No analytics, no ad SDKs, no third-party trackers.",
                          systemImage: "hand.raised.fill")
                    Text("The app only contacts the GIF service you search (Giphy or Tenor) and the CDN hosting a GIF you choose to send. Your badge is reached directly over Bluetooth — nothing about it is uploaded anywhere.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Privacy")
                }

                Section {
                    LabeledContent("Version", value: "0.1.0")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
