import Foundation
import BitChordKit

/// The app's only door to YouTube Music: wraps the Kotlin `MusicService` and
/// returns Swift models. Kotlin suspend functions arrive here as `async throws`.
final class CatalogService {
    private let service: MusicService
    private let javaScriptHost = WebViewJavaScriptHost()

    init() {
        let locale = Locale.current
        service = MusicService(
            store: UserDefaultsStore(),
            javaScriptHost: javaScriptHost,
            language: locale.language.languageCode?.identifier ?? "en",
            region: locale.region?.identifier ?? "US",
            logger: OSLogKitLogger()
        )
        service.setDebugLogging(enabled: UserDefaults.standard.bool(forKey: "debugLogging"))
    }

    func setDebugLogging(_ enabled: Bool) {
        service.setDebugLogging(enabled: enabled)
    }

    func warmUp() async {
        try? await service.warmUp()
    }

    // MARK: Browse

    func home() async throws -> (shelves: [ShelfModel], continuation: String?) {
        let page = try await service.home()
        return (page.shelves.map(ShelfModel.init), page.continuation)
    }

    func homeContinuation(_ token: String) async throws -> (shelves: [ShelfModel], continuation: String?) {
        let page = try await service.homeContinuation(token: token)
        return (page.shelves.map(ShelfModel.init), page.continuation)
    }

    func newReleases() async throws -> [ShelfModel] {
        try await service.latestReleases().map(ShelfModel.init)
    }

    func categories() async throws -> [CategoryModel] {
        try await service.categories().map {
            CategoryModel(title: $0.title, browseId: $0.browseId, params: $0.params,
                          colorARGB: $0.color?.int64Value, artworkURL: $0.artworkUrl.flatMap(URL.init(string:)))
        }
    }

    func categoryShelves(_ category: CategoryModel) async throws -> [ShelfModel] {
        try await service.categoryShelves(browseId: category.browseId, params: category.params).map(ShelfModel.init)
    }

    // MARK: Search

    enum Scope: CaseIterable, Hashable {
        case all, songs, albums, artists, playlists

        var title: String {
            switch self {
            case .all: "Top Results"
            case .songs: "Songs"
            case .albums: "Albums"
            case .artists: "Artists"
            case .playlists: "Playlists"
            }
        }

        fileprivate var kit: SearchScope {
            switch self {
            case .all: .all
            case .songs: .songs
            case .albums: .albums
            case .artists: .artists
            case .playlists: .playlists
            }
        }
    }

    func search(_ query: String, scope: Scope) async throws -> SearchModel {
        let results = try await service.search(query: query, scope: scope.kit)
        return SearchModel(
            top: results.top.map(Card.init),
            songs: results.songs.map(Song.init),
            albums: results.albums.map(Card.init),
            artists: results.artists.map(Card.init),
            playlists: results.playlists.map(Card.init),
            videos: results.videos.map(Song.init)
        )
    }

    func suggestions(_ input: String) async throws -> [String] {
        try await service.searchSuggestions(input: input)
    }

    // MARK: Pages

    func collection(_ browseId: String) async throws -> CollectionModel {
        let page = try await service.collection(browseId: browseId)
        return CollectionModel(
            browseId: page.browseId, kind: CardKind(page.kind), title: page.title, subtitle: page.subtitle,
            artworkURL: page.artworkUrl.flatMap(URL.init(string:)), about: page.about,
            songs: page.tracks.map(Song.init), continuation: page.continuation
        )
    }

    func moreSongs(_ continuation: String) async throws -> (songs: [Song], continuation: String?) {
        let page = try await service.moreTracks(continuation: continuation)
        return (page.tracks.map(Song.init), page.continuation)
    }

    /// Every song of a collection, following continuations (for "Play" on a card).
    func allSongs(of browseId: String, limit: Int = 500) async throws -> [Song] {
        var page = try await collection(browseId)
        var songs = page.songs
        while let token = page.continuation, songs.count < limit {
            let more = try await moreSongs(token)
            songs += more.songs
            page.continuation = more.continuation
        }
        return songs
    }

    func artist(_ browseId: String) async throws -> ArtistModel {
        let page = try await service.artist(browseId: browseId)
        return ArtistModel(
            browseId: page.browseId, name: page.name, artworkURL: page.artworkUrl.flatMap(URL.init(string:)),
            about: page.about, subscriberText: page.subscriberText, monthlyListeners: page.monthlyListeners,
            topSongs: page.topSongs.map(Song.init), shelves: page.shelves.map(ShelfModel.init),
            radio: page.radioPlaylistId.map { WatchTarget(playlistId: $0, params: page.radioParams) },
            shuffle: page.shufflePlaylistId.map { WatchTarget(playlistId: $0, params: page.shuffleParams) }
        )
    }

    /// YouTube Music's own continuation of a song (its radio / autoplay queue).
    func upNext(after videoId: String) async throws -> [Song] {
        try await service.upNext(videoId: videoId, playlistId: nil, params: nil).map(Song.init)
    }

    func queue(for target: WatchTarget) async throws -> [Song] {
        try await service.upNext(videoId: nil, playlistId: target.playlistId, params: target.params).map(Song.init)
    }

    // MARK: Playback

    func stream(for videoId: String, excluding profiles: [String] = []) async throws -> PlayableStream {
        try await service.resolveStream(videoId: videoId, excludedProfiles: profiles)
    }
}
