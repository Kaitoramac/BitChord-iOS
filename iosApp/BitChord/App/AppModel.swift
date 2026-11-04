import SwiftUI

enum AppTab: Hashable {
    case home, new, radio, library, search
}

/// App-wide state: the services, the selected tab, each tab's navigation path.
@MainActor
final class AppModel: ObservableObject {
    let catalog: CatalogService
    let library: LibraryStore
    let player: Player

    @Published var tab: AppTab = .home
    @Published var paths: [AppTab: NavigationPath] = [:]
    @Published var showsNowPlaying = false
    @Published var toast: String?

    init() {
        let catalog = CatalogService()
        let library = LibraryStore()
        self.catalog = catalog
        self.library = library
        self.player = Player(catalog: catalog, library: library)
        Task { await catalog.warmUp() }
    }

    func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[tab] ?? NavigationPath() },
            set: { self.paths[tab] = $0 }
        )
    }

    /// Opens a page in the current tab (Search pushes onto Search, and so on).
    func open(_ route: Route) {
        showsNowPlaying = false
        let target = tab
        var path = paths[target] ?? NavigationPath()
        path.append(route)
        paths[target] = path
    }

    // MARK: Card actions

    /// Plays every song of an album, playlist or artist card.
    func play(_ card: Card, shuffled: Bool) {
        if let song = card.song {
            player.play(song)
            return
        }
        Task {
            do {
                let songs = try await songs(of: card)
                player.play(songs, shuffled: shuffled)
            } catch {
                show("Couldn't play “\(card.title)”")
            }
        }
    }

    func enqueue(_ card: Card, next: Bool) {
        Task {
            do {
                let songs = try await card.song.map { [$0] } ?? songs(of: card)
                next ? player.playNext(songs) : player.addToQueue(songs)
                show(next ? "Playing Next" : "Added to Queue")
            } catch {
                show("Couldn't add “\(card.title)”")
            }
        }
    }

    private func songs(of card: Card) async throws -> [Song] {
        guard let browseId = card.browseId else { return [] }
        if card.kind == .artist {
            return try await catalog.artist(browseId).topSongs
        }
        return try await catalog.allSongs(of: browseId)
    }

    func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if toast == message { toast = nil } }
        }
    }
}
