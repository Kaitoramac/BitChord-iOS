import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player

    var body: some View {
        List {
            Section {
                row("Playlists", symbol: "music.note.list", route: .libraryPlaylists)
                row("Artists", symbol: "music.mic", route: .libraryArtists)
                row("Albums", symbol: "square.stack", route: .libraryAlbums)
                row("Songs", symbol: "music.note", route: .librarySongs)
            }

            if !library.recentlyAdded.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                        ForEach(library.recentlyAdded) { card in
                            CardLink(card: card) {
                                GeometryReader { geometry in
                                    CardView(card: card, width: geometry.size.width)
                                }
                                .aspectRatio(0.78, contentMode: .fit)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Recently Added")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Add Music to Your Library",
                        systemImage: "music.note.house",
                        description: Text("Tap + on albums and playlists, or ★ on songs, and they'll show up here.")
                    )
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
    }

    private func row(_ title: String, symbol: String, route: Route) -> some View {
        NavigationLink(value: route) {
            Label {
                Text(title).font(.title3)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 6)
        }
    }
}

struct LibraryCardsView: View {
    enum Kind { case playlists, artists, albums }

    let section: Kind
    @EnvironmentObject private var library: LibraryStore

    private var cards: [Card] {
        switch section {
        case .playlists: library.playlists
        case .artists: library.artists
        case .albums: library.albums
        }
    }

    private var title: String {
        switch section {
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        }
    }

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView("No \(title)", systemImage: "music.note.list", description: Text("Saved \(title.lowercased()) appear here."))
            } else if section == .artists {
                List(cards) { card in
                    NavigationLink(value: card.route) {
                        HStack(spacing: 12) {
                            ArtworkImage(url: card.artworkURL, circle: true).frame(width: 44, height: 44)
                            Text(card.title)
                        }
                    }
                    .contextMenu { CardMenu(card: card) }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
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
                    .padding(20)
                }
            }
        }
        .navigationTitle(title)
    }
}

struct LibrarySongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player

    private var songs: [Song] { library.songs.map(\.song) }

    var body: some View {
        Group {
            if songs.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note", description: Text("Songs you star appear here."))
            } else {
                List {
                    PlayShuffleButtons(
                        play: { player.play(songs) },
                        shuffle: { player.play(songs, shuffled: true) }
                    )
                    .listRowSeparator(.hidden)
                    ForEach(Array(songs.enumerated()), id: \.element.id) { offset, song in
                        Button { player.play(songs, startAt: offset) } label: {
                            SongRow(song: song, isCurrent: player.current == song)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { library.toggle(song) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Songs")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("normalizeVolume") private var normalizeVolume = true
    @AppStorage("debugLogging") private var debugLogging = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Toggle("Sound Check", isOn: $normalizeVolume)
                    LabeledContent("Audio Format", value: "AAC (MP4)")
                }
                Section("Account") {
                    LabeledContent("YouTube Music", value: "Not signed in")
                    Text("Signing in to sync your YouTube Music library is on the roadmap.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    Toggle("Verbose Logging", isOn: $debugLogging)
                        .onChange(of: debugLogging) { _, enabled in app.catalog.setDebugLogging(enabled) }
                    if let info = app.player.streamInfo {
                        LabeledContent("Current Stream", value: info)
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("BitChord (GPL-3.0)", destination: URL(string: "https://github.com/kushagrasinghx/BitChord")!)
                    Link("InnerTubeX (GPL-3.0)", destination: URL(string: "https://github.com/MetrolistGroup/innertubex")!)
                    Link("Lyrics by LRCLIB", destination: URL(string: "https://lrclib.net")!)
                    Text("Not affiliated with YouTube, Google or Apple.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
