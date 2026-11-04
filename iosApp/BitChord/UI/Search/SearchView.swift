import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore

    @State private var query = ""
    @State private var submitted = ""
    @State private var scope: CatalogService.Scope = .all
    @State private var suggestions: [String] = []
    @State private var results: LoadState<SearchModel>?
    @State private var categories: [CategoryModel] = []

    var body: some View {
        ScrollView {
            if submitted.isEmpty {
                browse
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Scope", selection: $scope) {
                        ForEach(CatalogService.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    resultsView
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, Songs, Lyrics and More")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "magnifyingglass")
                    .searchCompletion(suggestion)
            }
        }
        .onSubmit(of: .search) { submit(query) }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty {
                submitted = ""
                results = nil
            }
        }
        .onChange(of: scope) { _, _ in
            if !submitted.isEmpty { Task { await search() } }
        }
        .task(id: query) {
            // Debounced suggestions as the user types.
            guard !query.isEmpty, query != submitted else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestions = (try? await app.catalog.suggestions(query)) ?? []
        }
        .task {
            if categories.isEmpty { categories = (try? await app.catalog.categories()) ?? [] }
        }
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submitted = trimmed
        suggestions = []
        library.recordSearch(trimmed)
        Task { await search() }
    }

    private func search() async {
        let current = submitted
        results = .loading
        do {
            let found = try await app.catalog.search(current, scope: scope)
            if current == submitted { results = .loaded(found) }
        } catch {
            if current == submitted { results = .failed(error.localizedDescription) }
        }
    }

    // MARK: Before searching

    private var browse: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !library.recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recently Searched").font(.title3.bold())
                        Spacer()
                        Button("Clear") { library.clearRecentSearches() }
                    }
                    ForEach(library.recentSearches.prefix(6), id: \.self) { recent in
                        Button {
                            query = recent
                            submit(recent)
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(recent).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        Divider()
                    }
                }
                .padding(.horizontal, 20)
            }
            if !categories.isEmpty {
                Text("Browse Categories").font(.title3.bold()).padding(.horizontal, 20)
                CategoryGrid(categories: categories)
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsView: some View {
        switch results {
        case .none, .loading?:
            LoadingView()
        case .failed(let message)?:
            ErrorView(message: message) { Task { await search() } }
        case .loaded(let model)?:
            if model.isEmpty {
                ContentUnavailableView.search(text: submitted)
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if scope == .all, let top = model.top {
                        topResult(top)
                    }
                    if !model.songs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if scope == .all { ShelfHeader(title: "Songs") }
                            ForEach(Array((scope == .all ? Array(model.songs.prefix(6)) : model.songs).enumerated()), id: \.element.id) { offset, song in
                                Button { player.play(model.songs, startAt: offset) } label: {
                                    SongRow(song: song, isCurrent: player.current == song).padding(.horizontal, 20).padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 80)
                            }
                        }
                    }
                    cardRow("Artists", model.artists)
                    cardRow("Albums", model.albums)
                    cardRow("Playlists", model.playlists)
                    if !model.videos.isEmpty {
                        ShelfView(shelf: ShelfModel(title: "Music Videos", subtitle: "", layout: .video, cards: model.videos.map { Card(song: $0) }))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cardRow(_ title: String, _ cards: [Card]) -> some View {
        if !cards.isEmpty {
            if scope == .all {
                ShelfView(shelf: ShelfModel(title: title, subtitle: "", layout: .cards, cards: cards))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                    ForEach(cards) { card in
                        CardLink(card: card) {
                            GeometryReader { geometry in
                                CardView(card: card, width: geometry.size.width)
                            }
                            .aspectRatio(0.78, contentMode: .fit)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func topResult(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "Top Result")
            CardLink(card: card) {
                HStack(spacing: 14) {
                    ArtworkImage(url: card.artworkURL, circle: card.kind == .artist)
                        .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Text(card.kind == .artist ? "Artist" : card.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if card.kind.isPlayable {
                        Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 20)
        }
    }
}
