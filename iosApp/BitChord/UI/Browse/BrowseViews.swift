import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LibraryStore

    @State private var state: LoadState<[ShelfModel]> = .loading
    @State private var continuation: String?
    @State private var loadingMore = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if !library.recentlyPlayed.isEmpty {
                    ShelfView(shelf: ShelfModel(
                        title: "Recently Played", subtitle: "", layout: .cards,
                        cards: library.recentlyPlayed.prefix(15).map { Card(song: $0) }
                    ))
                }
                switch state {
                case .loading:
                    LoadingView()
                case .failed(let message):
                    ErrorView(message: message) { Task { await load() } }
                case .loaded(let shelves):
                    ForEach(shelves) { shelf in
                        ShelfView(shelf: shelf)
                    }
                    if continuation != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear { Task { await loadMore() } }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Home")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
        .refreshable { await load() }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            let page = try await app.catalog.home()
            state = .loaded(page.shelves)
            continuation = page.continuation
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
        }
    }

    private func loadMore() async {
        guard !loadingMore, let token = continuation, case .loaded(let shelves) = state else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await app.catalog.homeContinuation(token) else {
            continuation = nil
            return
        }
        let known = Set(shelves.map(\.id))
        state = .loaded(shelves + page.shelves.filter { !known.contains($0.id) })
        continuation = page.continuation
    }
}

// MARK: - New

struct NewView: View {
    @EnvironmentObject private var app: AppModel
    @State private var state: LoadState<[ShelfModel]> = .loading

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                switch state {
                case .loading:
                    LoadingView()
                case .failed(let message):
                    ErrorView(message: message) { Task { await load() } }
                case .loaded(let shelves):
                    if let hero = shelves.first, !hero.cards.isEmpty {
                        HeroCarousel(cards: Array(hero.cards.prefix(8)))
                    }
                    ForEach(shelves) { shelf in
                        ShelfView(shelf: shelf)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("New")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
        .refreshable { await load() }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            state = .loaded(try await app.catalog.newReleases())
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
        }
    }
}

/// The wide, paged cards at the top of New.
struct HeroCarousel: View {
    let cards: [Card]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(cards) { card in
                    CardLink(card: card) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(card.kind.label.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(card.title).font(.title3).lineLimit(1)
                            Text(card.subtitle).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                            ArtworkImage(url: card.artworkURL, aspectRatio: 1.5)
                                .padding(.top, 4)
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in width - 40 }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - Radio

/// Stations by mood and genre, as colourful tiles.
struct RadioView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @State private var state: LoadState<[CategoryModel]> = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let seed = player.current ?? library.recentlyPlayed.first {
                    Button { player.startRadio(from: seed) } label: {
                        HStack(spacing: 14) {
                            ArtworkImage(url: seed.artworkURL, cornerRadius: 10)
                                .frame(width: 84, height: 84)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("STATION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text("\(seed.title) Station").font(.title3.weight(.semibold)).lineLimit(2)
                                Text("Based on \(seed.artist)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(Theme.accent)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }

                ShelfHeader(title: "Moods & Genres")
                switch state {
                case .loading:
                    LoadingView()
                case .failed(let message):
                    ErrorView(message: message) { Task { await load() } }
                case .loaded(let categories):
                    CategoryGrid(categories: categories)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Radio")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            state = .loaded(try await app.catalog.categories())
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
        }
    }
}

struct CategoryGrid: View {
    let categories: [CategoryModel]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(categories) { category in
                NavigationLink(value: Route.category(category)) {
                    CategoryTile(category: category)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }
}

struct CategoryTile: View {
    let category: CategoryModel

    private var color: Color {
        guard let argb = category.colorARGB else {
            // A stable colour per title when YouTube gives none.
            let seed = category.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            let hue = Double(seed % 360) / 360
            return Color(hue: hue, saturation: 0.55, brightness: 0.7)
        }
        return Color(
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255
        )
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .padding(12)
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CategoryView: View {
    let category: CategoryModel

    @EnvironmentObject private var app: AppModel
    @State private var state: LoadState<[ShelfModel]> = .loading

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                switch state {
                case .loading: LoadingView()
                case .failed(let message): ErrorView(message: message) { Task { await load() } }
                case .loaded(let shelves): ForEach(shelves) { ShelfView(shelf: $0) }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(category.title)
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        do {
            state = .loaded(try await app.catalog.categoryShelves(category))
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
        }
    }
}

// MARK: - Account

struct AccountButton: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @State private var showsSettings = false

    var body: some View {
        Button { showsSettings = true } label: {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(Theme.accent)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
                .environmentObject(app)
                .environmentObject(player)
                .environmentObject(library)
        }
    }
}
