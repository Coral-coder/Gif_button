import SwiftUI

struct RootView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager

    var body: some View {
        TabView {
            SearchView()
                .tabItem { Label("GIFs", systemImage: "magnifyingglass") }

            MarqueeView()
                .tabItem { Label("Text", systemImage: "textformat") }

            DeviceView()
                .tabItem { Label("Badge", systemImage: "dot.radiowaves.left.and.right") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
