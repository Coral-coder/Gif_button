import PhotosUI
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [GifItem] = []
    @Published var isLoading = false        // first page
    @Published var isLoadingMore = false    // subsequent pages
    @Published var errorMessage: String?
    @Published var source: GifSource = .giphy

    private enum Mode: Equatable { case trending; case search(String) }
    private var mode: Mode = .trending
    private var cursor: String?
    private var canLoadMore = true
    private let pageSize = 30

    private func provider(_ settings: AppSettings) -> GifProvider {
        switch source {
        case .tenor: return TenorProvider(apiKey: settings.effectiveTenorKey)
        case .klipy: return KlipyProvider(apiKey: settings.effectiveKlipyKey)
        default: return GiphyProvider(apiKey: settings.effectiveGiphyKey)
        }
    }

    /// (Re)load the first page for the current query/source.
    func reload(_ settings: AppSettings) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        mode = q.isEmpty ? .trending : .search(q)
        cursor = nil
        canLoadMore = true
        results = []
        errorMessage = nil
        isLoading = true
        await fetchPage(settings, isFirst: true)
        isLoading = false
    }

    /// Load the next page when the user nears the end of the grid.
    func loadMoreIfNeeded(current item: GifItem, _ settings: AppSettings) async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }
        guard let idx = results.firstIndex(of: item), idx >= results.count - 8 else { return }
        isLoadingMore = true
        await fetchPage(settings, isFirst: false)
        isLoadingMore = false
    }

    private func fetchPage(_ settings: AppSettings, isFirst: Bool) async {
        do {
            let page: GifPage
            switch mode {
            case .trending:
                page = try await provider(settings).trending(cursor: cursor, limit: pageSize)
            case .search(let q):
                page = try await provider(settings).search(query: q, cursor: cursor, limit: pageSize)
            }
            // Dedupe by id — providers occasionally repeat items across pages,
            // and duplicate ForEach ids would break the grid.
            let seen = Set(results.map(\.id))
            results.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            cursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            if isFirst && results.isEmpty && errorMessage == nil { errorMessage = "No results." }
        } catch {
            errorMessage = error.localizedDescription
            canLoadMore = false
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vm: SearchViewModel
    @EnvironmentObject private var queue: SendQueue

    @State private var pending: PendingSend?
    @State private var photoItem: PhotosPickerItem?
    @State private var showURLPrompt = false
    @State private var showQueue = false
    @State private var urlText = ""

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Source", selection: $vm.source) {
                    Text("Giphy").tag(GifSource.giphy)
                    Text("Tenor").tag(GifSource.tenor)
                    Text("Klipy").tag(GifSource.klipy)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if let error = vm.errorMessage, vm.results.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(error).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(vm.results) { item in
                                Button {
                                    pending = PendingSend(title: item.title,
                                                          previewURL: item.previewURL,
                                                          source: .remote(item.fullURL))
                                } label: {
                                    GifThumbnail(url: item.previewURL)
                                }
                                .buttonStyle(.plain)
                                .task { await vm.loadMoreIfNeeded(current: item, settings) }
                            }
                        }
                        .padding(.horizontal, 8)

                        if vm.isLoadingMore {
                            ProgressView().padding(.vertical, 12)
                        }
                    }
                    .overlay { if vm.isLoading { ProgressView() } }
                }
            }
            .background(AeroBackground())
            .navigationTitle("Find a GIF")
            .searchable(text: $vm.query, prompt: "Search GIFs")
            .onSubmit(of: .search) { Task { await vm.reload(settings) } }
            .task {
                // Load once on first appearance; don't wipe results on tab switch.
                if vm.results.isEmpty { await vm.reload(settings) }
            }
            .onChange(of: vm.source) { _ in Task { await vm.reload(settings) } }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showQueue = true } label: {
                        Image(systemName: (queue.jobs.isEmpty && !queue.isDraining) ? "tray" : "tray.full")
                            .overlay(alignment: .topTrailing) {
                                if !queue.jobs.isEmpty {
                                    Text("\(queue.jobs.count)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(Circle().fill(.red))
                                        .offset(x: 9, y: -9)
                                }
                            }
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    Button { showURLPrompt = true } label: { Image(systemName: "link") }
                }
            }
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        pending = PendingSend(title: "From Photos", previewURL: nil, source: .data(data))
                    }
                    photoItem = nil
                }
            }
            .alert("Send from URL", isPresented: $showURLPrompt) {
                TextField("https://…/image.gif", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Cancel", role: .cancel) { urlText = "" }
                Button("Load") {
                    if let url = Self.normalizedURL(urlText) {
                        pending = PendingSend(title: "From URL", previewURL: url, source: .remote(url))
                    }
                    urlText = ""
                }
            } message: {
                Text("Paste a direct link to a GIF or image.")
            }
            .sheet(item: $pending) { item in
                SendMediaView(pending: item)
            }
            .sheet(isPresented: $showQueue) { QueueView() }
        }
    }

    private static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }
}

/// GIF thumbnail. AsyncImage shows the first frame (it doesn't animate GIFs),
/// which is fine for a picker grid.
struct GifThumbnail: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Color.gray.opacity(0.2).overlay(Image(systemName: "xmark").foregroundStyle(.secondary))
            default:
                Color.gray.opacity(0.15).overlay(ProgressView())
            }
        }
        .frame(height: 108)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
