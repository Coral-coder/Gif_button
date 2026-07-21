import SwiftUI

struct RootView: View {
    @EnvironmentObject private var queue: SendQueue
    @State private var showQueue = false

    var body: some View {
        TabView {
            SearchView()
                .tabItem { Label("GIFs", systemImage: "magnifyingglass") }

            DeviceView()
                .tabItem { Label("Badge", systemImage: "dot.radiowaves.left.and.right") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.aeroAccent)
        // App-wide upload popup: visible on any tab while the queue drains.
        .overlay(alignment: .bottom) {
            if queue.isDraining {
                UploadHUD { showQueue = true }
                    .padding(.bottom, 52) // sit above the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: queue.isDraining)
        .sheet(isPresented: $showQueue) { QueueView() }
    }
}
