import PhotosUI
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

    @State private var pending: PendingSend?
    @State private var photoItem: PhotosPickerItem?
    @State private var showURLPrompt = false
    @State private var urlText = ""

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
            .toolbar {
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
