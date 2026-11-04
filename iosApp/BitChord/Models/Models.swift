import Foundation
import BitChordKit

// Swift-side models. The Kotlin types stop at CatalogService: the UI and the
// player work with these value types, which are Hashable and Codable (for the
// library and the saved queue), and do not change when the Kotlin side does.

struct Song: Identifiable, Hashable, Codable {
    var videoId: String
    var title: String
    var artist: String
    var artistId: String?
    var album: String?
    var albumId: String?
    var artworkURL: URL?
    var durationText: String?
    var isVideo: Bool = false

    var id: String { videoId }

    /// "3:45" → 225. Nil when YouTube gave no duration.
    var durationSeconds: Double? {
        guard let text = durationText else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

enum CardKind: String, Codable, Hashable {
    case song, video, album, single, playlist, artist, podcast, other

    var isPlayable: Bool { self == .song || self == .video }

    var label: String {
        switch self {
        case .song: "Song"
        case .video: "Music Video"
        case .album: "Album"
        case .single: "Single"
        case .playlist: "Playlist"
        case .artist: "Artist"
        case .podcast: "Podcast"
        case .other: ""
        }
    }
}

/// A tile in a shelf, a search result, or a library entry.
struct Card: Identifiable, Hashable, Codable {
    var kind: CardKind
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var videoId: String?
    var browseId: String?

    var id: String { videoId ?? browseId ?? "\(kind.rawValue):\(title):\(subtitle)" }

    var route: Route? {
        guard let browseId else { return nil }
        switch kind {
        case .artist: return .artist(browseId)
        case .album, .single, .playlist, .podcast, .other: return .collection(browseId)
        case .song, .video: return nil
        }
    }

    /// A playable card as a queue entry (shelves carry no duration or album).
    var song: Song? {
        guard let videoId else { return nil }
        return Song(videoId: videoId, title: title, artist: subtitle.components(separatedBy: " • ").first ?? subtitle,
                    artworkURL: artworkURL, isVideo: kind == .video)
    }
}

enum ShelfLayout: Hashable {
    case cards, list, video
}

struct ShelfModel: Identifiable, Hashable {
    var title: String
    var subtitle: String
    var layout: ShelfLayout
    var cards: [Card]

    var id: String { title + subtitle }
}

struct CollectionModel: Hashable {
    var browseId: String
    var kind: CardKind
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var about: String?
    var songs: [Song]
    var continuation: String?

    /// "Album • Daft Punk • 1997" → ["Album", "Daft Punk", "1997"].
    private var subtitleParts: [String] {
        subtitle.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The artist line under the title (Apple Music shows it in the accent colour).
    var byline: String {
        let parts = subtitleParts
        if parts.count >= 2, ["Album", "Single", "EP", "Playlist"].contains(parts[0]) { return parts[1] }
        return parts.first ?? ""
    }

    /// "Album · 1997" under the byline.
    var detailLine: String {
        let parts = subtitleParts
        guard parts.count >= 2 else { return "" }
        return ([parts[0]] + parts.dropFirst(2)).joined(separator: " · ")
    }

    var totalDurationText: String? {
        let seconds = songs.compactMap(\.durationSeconds).reduce(0, +)
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) minutes"
    }

    var asCard: Card {
        Card(kind: kind, title: title, subtitle: byline, artworkURL: artworkURL, videoId: nil, browseId: browseId)
    }
}

struct ArtistModel: Hashable {
    var browseId: String
    var name: String
    var artworkURL: URL?
    var about: String?
    var subscriberText: String?
    var monthlyListeners: String?
    var topSongs: [Song]
    var shelves: [ShelfModel]
    var radio: WatchTarget?
    var shuffle: WatchTarget?

    var asCard: Card {
        Card(kind: .artist, title: name, subtitle: "Artist", artworkURL: artworkURL, videoId: nil, browseId: browseId)
    }
}

struct WatchTarget: Hashable {
    var playlistId: String
    var params: String?
}

struct CategoryModel: Identifiable, Hashable {
    var title: String
    var browseId: String
    var params: String?
    var colorARGB: Int64?
    var artworkURL: URL?

    var id: String { browseId + (params ?? "") }
}

struct SearchModel {
    var top: Card?
    var songs: [Song] = []
    var albums: [Card] = []
    var artists: [Card] = []
    var playlists: [Card] = []
    var videos: [Song] = []

    var isEmpty: Bool { top == nil && songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty && videos.isEmpty }
}

enum Route: Hashable {
    case collection(String)
    case artist(String)
    case category(CategoryModel)
    case libraryPlaylists, libraryArtists, libraryAlbums, librarySongs
}

// MARK: - From the Kotlin types

extension Song {
    init(_ track: Track) {
        self.init(videoId: track.videoId, title: track.title, artist: track.artist, artistId: track.artistId,
                  album: track.album, albumId: track.albumId, artworkURL: track.artworkUrl.flatMap(URL.init(string:)),
                  durationText: track.durationText, isVideo: track.isVideo)
    }
}

extension CardKind {
    init(_ kind: ItemKind) {
        switch kind {
        case .song: self = .song
        case .video: self = .video
        case .album: self = .album
        case .single: self = .single
        case .playlist: self = .playlist
        case .artist: self = .artist
        case .podcast: self = .podcast
        default: self = .other
        }
    }
}

extension Card {
    init(_ item: MediaItem) {
        self.init(kind: CardKind(item.kind), title: item.title, subtitle: item.subtitle,
                  artworkURL: item.artworkUrl.flatMap(URL.init(string:)), videoId: item.videoId, browseId: item.browseId)
    }

    init(song: Song) {
        self.init(kind: song.isVideo ? .video : .song, title: song.title, subtitle: song.artist,
                  artworkURL: song.artworkURL, videoId: song.videoId, browseId: nil)
    }
}

extension ShelfModel {
    init(_ shelf: Shelf) {
        let layout: ShelfLayout
        switch shelf.style {
        case .list: layout = .list
        case .video: layout = .video
        default: layout = .cards
        }
        self.init(title: shelf.title, subtitle: shelf.subtitle, layout: layout, cards: shelf.items.map(Card.init))
    }
}
