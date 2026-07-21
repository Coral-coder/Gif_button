import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [GifItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var source: GifSource = .giphy

    private func provider(_ settings: AppSettings) -> GifProvider {
        switch source {
        case .tenor: return TenorProvider(apiKey: settings.tenorAPIKey)
        default: return GiphyProvider(apiKey: settings.giphyAPIKey)
        }
    }

    func loadTrending(_ settings: AppSettings) async {
        await run { try await self.provider(settings).trending(limit: 30) }
    }

    func search(_ settings: AppSettings) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { await loadTrending(settings); return }
        await run { try await self.provider(settings).search(query: q, limit: 30) }
    }

    private func run(_ work: @escaping () async throws -> [GifItem]) async {
        isLoading = true
        errorMessage = nil
        do {
            results = try await work()
            if results.isEmpty { errorMessage = "No results." }
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct SearchView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var vm = SearchViewModel()
    @State private var selected: GifItem?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Source", selection: $vm.source) {
                    Text("Giphy").tag(GifSource.giphy)
                    Text("Tenor").tag(GifSource.tenor)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if let error = vm.errorMessage, vm.results.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
                        Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(vm.results) { item in
                                Button { selected = item } label: {
                                    GifThumbnail(url: item.previewURL)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .overlay { if vm.isLoading { ProgressView() } }
                }
            }
            .navigationTitle("Find a GIF")
            .searchable(text: $vm.query, prompt: "Search GIFs")
            .onSubmit(of: .search) { Task { await vm.search(settings) } }
            .task { await vm.loadTrending(settings) }
            .onChange(of: vm.source) { _ in Task { await vm.search(settings) } }
            .sheet(item: $selected) { item in
                GifDetailView(item: item)
            }
        }
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
