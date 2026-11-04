import Foundation

/// The user's library, kept on the device: saved albums, playlists, artists and
/// songs, plus recently played. (Syncing with a YouTube Music account comes later.)
@MainActor
final class LibraryStore: ObservableObject {
    struct Entry: Codable, Hashable, Identifiable {
        var card: Card
        var addedAt: Date
        var id: String { card.id }
    }

    struct SavedSong: Codable, Hashable, Identifiable {
        var song: Song
        var addedAt: Date
        var id: String { song.id }
    }

    @Published private(set) var collections: [Entry] = []
    @Published private(set) var songs: [SavedSong] = []
    @Published private(set) var recentlyPlayed: [Song] = []
    @Published private(set) var recentSearches: [String] = []

    var playlists: [Card] { collections.filter { $0.card.kind == .playlist || $0.card.kind == .podcast }.map(\.card) }
    var albums: [Card] { collections.filter { $0.card.kind == .album || $0.card.kind == .single }.map(\.card) }
    var artists: [Card] { collections.filter { $0.card.kind == .artist }.map(\.card) }
    var recentlyAdded: [Card] {
        let saved = collections.map { ($0.card, $0.addedAt) } + songs.map { (Card(song: $0.song), $0.addedAt) }
        return saved.sorted { $0.1 > $1.1 }.prefix(24).map(\.0)
    }

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("library.json")
        load()
    }

    // MARK: Collections

    func contains(_ card: Card) -> Bool {
        if let videoId = card.videoId { return songs.contains { $0.song.videoId == videoId } }
        return collections.contains { $0.card.id == card.id }
    }

    func toggle(_ card: Card) {
        if let song = card.song {
            toggle(song)
        } else if contains(card) {
            collections.removeAll { $0.card.id == card.id }
            save()
        } else {
            collections.insert(Entry(card: card, addedAt: Date()), at: 0)
            save()
        }
    }

    // MARK: Songs

    func contains(_ song: Song) -> Bool {
        songs.contains { $0.song.videoId == song.videoId }
    }

    func toggle(_ song: Song) {
        if contains(song) {
            songs.removeAll { $0.song.videoId == song.videoId }
        } else {
            songs.insert(SavedSong(song: song, addedAt: Date()), at: 0)
        }
        save()
    }

    func add(_ newSongs: [Song]) {
        let known = Set(songs.map(\.song.videoId))
        songs.insert(contentsOf: newSongs.filter { !known.contains($0.videoId) }.map { SavedSong(song: $0, addedAt: Date()) }, at: 0)
        save()
    }

    // MARK: History

    func recordPlay(_ song: Song) {
        recentlyPlayed.removeAll { $0.videoId == song.videoId }
        recentlyPlayed.insert(song, at: 0)
        if recentlyPlayed.count > 100 { recentlyPlayed.removeLast(recentlyPlayed.count - 100) }
        save()
    }

    func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > 20 { recentSearches.removeLast() }
        save()
    }

    func clearRecentSearches() {
        recentSearches = []
        save()
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var collections: [Entry]
        var songs: [SavedSong]
        var recentlyPlayed: [Song]
        var recentSearches: [String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        collections = snapshot.collections
        songs = snapshot.songs
        recentlyPlayed = snapshot.recentlyPlayed
        recentSearches = snapshot.recentSearches
    }

    private func save() {
        let snapshot = Snapshot(collections: collections, songs: songs, recentlyPlayed: recentlyPlayed, recentSearches: recentSearches)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
