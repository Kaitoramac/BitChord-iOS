import SwiftUI

// MARK: - Album / playlist

struct CollectionView: View {
    let browseId: String

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore

    @State private var state: LoadState<CollectionModel> = .loading
    @State private var loadingMore = false
    @State private var showsAbout = false

    var body: some View {
        ScrollView {
            switch state {
            case .loading:
                LoadingView().padding(.top, 120)
            case .failed(let message):
                ErrorView(message: message) { Task { await load() } }
            case .loaded(let page):
                content(page)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let page = state.value {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { library.toggle(page.asCard) } label: {
                        Image(systemName: library.contains(page.asCard) ? "checkmark" : "plus")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Menu {
                        CardMenu(card: page.asCard)
                        ShareLink(item: URL(string: "https://music.youtube.com/browse/\(page.browseId)")!) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .task { if state.value == nil { await load() } }
    }

    @ViewBuilder
    private func content(_ page: CollectionModel) -> some View {
        let isAlbum = page.kind == .album || page.kind == .single
        LazyVStack(spacing: 0) {
            VStack(spacing: 6) {
                ArtworkImage(url: page.artworkURL, cornerRadius: 10)
                    .frame(width: 260, height: 260)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                    .padding(.bottom, 14)
                Text(page.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if !page.byline.isEmpty {
                    Text(page.byline)
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                }
                if !page.detailLine.isEmpty {
                    Text(page.detailLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                PlayShuffleButtons(
                    play: { player.play(page.songs) },
                    shuffle: { player.play(page.songs, shuffled: true) }
                )
                .padding(.top, 14)
                .disabled(page.songs.isEmpty)

                if let about = page.about, !about.isEmpty {
                    Button { showsAbout = true } label: {
                        Text(about)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                    .sheet(isPresented: $showsAbout) {
                        NavigationStack {
                            ScrollView { Text(about).padding() }
                                .navigationTitle(page.title)
                                .navigationBarTitleDisplayMode(.inline)
                        }
                        .presentationDetents([.medium, .large])
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider().padding(.leading, 20)

            ForEach(Array(page.songs.enumerated()), id: \.element.id) { offset, song in
                Button {
                    player.play(page.songs, startAt: offset)
                } label: {
                    SongRow(song: song, number: isAlbum ? offset + 1 : nil, showsArtist: !isAlbum || song.artist != page.byline,
                            isCurrent: player.current == song)
                        .padding(.vertical, isAlbum ? 10 : 6)
                        .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if song == page.songs.last { Task { await loadMore() } }
                }
                Divider().padding(.leading, isAlbum ? 56 : 80)
            }

            if loadingMore { ProgressView().padding() }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(page.songs.count) songs" + (page.totalDurationText.map { ", \($0)" } ?? ""))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .padding(.top, 8)
    }

    private func load() async {
        do {
            state = .loaded(try await app.catalog.collection(browseId))
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
        }
    }

    private func loadMore() async {
        guard !loadingMore, var page = state.value, let token = page.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let more = try? await app.catalog.moreSongs(token) else { return }
        let known = Set(page.songs.map(\.videoId))
        page.songs += more.songs.filter { !known.contains($0.videoId) }
        page.continuation = more.continuation
        state = .loaded(page)
    }
}

// MARK: - Artist

struct ArtistView: View {
    let browseId: String

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore

    @State private var state: LoadState<ArtistModel> = .loading

    var body: some View {
        ScrollView {
            switch state {
            case .loading:
                LoadingView().padding(.top, 160)
            case .failed(let message):
                ErrorView(message: message) { Task { await load() } }
            case .loaded(let artist):
                content(artist)
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            if let artist = state.value {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { library.toggle(artist.asCard) } label: {
                        Image(systemName: library.contains(artist.asCard) ? "star.fill" : "star")
                    }
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { if state.value == nil { await load() } }
    }

    private func content(_ artist: ArtistModel) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            header(artist)

            if !artist.topSongs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeader(title: "Top Songs")
                    SongColumns(songs: artist.topSongs)
                }
            }

            ForEach(artist.shelves) { shelf in
                ShelfView(shelf: shelf)
            }

            if let about = artist.about, !about.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ShelfHeader(title: "About \(artist.name)")
                    Text(about)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .padding(.horizontal, 20)
                    if let listeners = artist.monthlyListeners ?? artist.subscriberText {
                        Text(listeners)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// Full-bleed photo that stretches when pulled down, name over it, and the play button.
    private func header(_ artist: ArtistModel) -> some View {
        GeometryReader { geometry in
            let pull = max(geometry.frame(in: .scrollView).minY, 0)
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(url: artist.artworkURL, cornerRadius: 0)
                    .frame(width: geometry.size.width, height: geometry.size.height + pull)
                    .clipped()
                    .offset(y: -pull)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .offset(y: -pull)
                HStack(alignment: .bottom) {
                    Text(artist.name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Button {
                        Task { await playArtist(artist) }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Theme.accent, in: Circle())
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    }
                }
                .padding(20)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func playArtist(_ artist: ArtistModel) async {
        if let shuffle = artist.shuffle, let songs = try? await app.catalog.queue(for: shuffle), !songs.isEmpty {
            player.play(songs)
        } else if let radio = artist.radio, let songs = try? await app.catalog.queue(for: radio), !songs.isEmpty {
            player.play(songs)
        } else {
            player.play(artist.topSongs, shuffled: true)
        }
    }

    private func load() async {
        do {
            state = .loaded(try await app.catalog.artist(browseId))
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) }
        }
    }
}
