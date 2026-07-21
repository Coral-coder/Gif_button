import SwiftUI

struct RootView: View {
    @EnvironmentObject private var queue: SendQueue
    @EnvironmentObject private var imports: ImportStore
    @Environment(\.scenePhase) private var scenePhase

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
        // Items shared into the app via the Share Extension.
        .sheet(item: importBinding) { item in SendMediaView(pending: item) }
        .onAppear { imports.ingest() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { imports.ingest() }
        }
    }

    /// Presents shared items one at a time; dismissing drops the current one.
    private var importBinding: Binding<PendingSend?> {
        Binding(
            get: { imports.pending.first },
            set: { newValue in
                if newValue == nil && !imports.pending.isEmpty {
                    imports.pending.removeFirst()
                }
            }
        )
    }
}
