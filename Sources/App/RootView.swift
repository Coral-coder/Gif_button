import SwiftUI

struct RootView: View {
    // Owned here (above the TabView) so switching tabs never loses your work.
    @StateObject private var searchVM = SearchViewModel()
    @StateObject private var marqueeDraft = MarqueeDraft()

    var body: some View {
        TabView {
            SearchView()
                .environmentObject(searchVM)
                .tabItem { Label("GIFs", systemImage: "magnifyingglass") }

            MarqueeView()
                .environmentObject(marqueeDraft)
                .tabItem { Label("Text", systemImage: "textformat") }

            DeviceView()
                .tabItem { Label("Badge", systemImage: "dot.radiowaves.left.and.right") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
