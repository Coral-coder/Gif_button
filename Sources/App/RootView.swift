import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            SearchView()
                .tabItem { Label("GIFs", systemImage: "magnifyingglass") }

            DeviceView()
                .tabItem { Label("Badge", systemImage: "dot.radiowaves.left.and.right") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
