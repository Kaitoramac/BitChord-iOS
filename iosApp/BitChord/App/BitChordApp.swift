import SwiftUI

@main
struct BitChordApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.player)
                .environmentObject(app.library)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        TabView(selection: $app.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: app.path(for: .home)) {
                    HomeView().withRoutes()
                }
                .miniPlayerInset()
            }
            Tab("New", systemImage: "square.grid.2x2.fill", value: AppTab.new) {
                NavigationStack(path: app.path(for: .new)) {
                    NewView().withRoutes()
                }
                .miniPlayerInset()
            }
            Tab("Radio", systemImage: "dot.radiowaves.left.and.right", value: AppTab.radio) {
                NavigationStack(path: app.path(for: .radio)) {
                    RadioView().withRoutes()
                }
                .miniPlayerInset()
            }
            Tab("Library", systemImage: "music.note.square.stack.fill", value: AppTab.library) {
                NavigationStack(path: app.path(for: .library)) {
                    LibraryView().withRoutes()
                }
                .miniPlayerInset()
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: app.path(for: .search)) {
                    SearchView().withRoutes()
                }
                .miniPlayerInset()
            }
        }
        .miniPlayerAccessory {
            MiniPlayerView()
        }
        .fullScreenCover(isPresented: $app.showsNowPlaying) {
            NowPlayingView()
                .environmentObject(app)
                .environmentObject(player)
                .environmentObject(library)
                .tint(Theme.accent)
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .alert("Playback", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
            Button("Skip") { player.next() }
        } message: {
            Text(player.errorMessage ?? "")
        }
    }
}

// MARK: - Navigation

extension View {
    /// The pages any tab can push.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .collection(let browseId): CollectionView(browseId: browseId)
            case .artist(let browseId): ArtistView(browseId: browseId)
            case .category(let category): CategoryView(category: category)
            case .libraryPlaylists: LibraryCardsView(section: .playlists)
            case .libraryArtists: LibraryCardsView(section: .artists)
            case .libraryAlbums: LibraryCardsView(section: .albums)
            case .librarySongs: LibrarySongsView()
            }
        }
    }

    /// The mini player sits in the tab bar's accessory slot on iOS 26 (Liquid
    /// Glass, as Apple Music does), and floats above the tab bar before that.
    @ViewBuilder
    func miniPlayerAccessory<Accessory: View>(@ViewBuilder _ accessory: () -> Accessory) -> some View {
        // Built once here: the closures below escape, and a non-escaping parameter cannot be captured by them.
        let content = accessory()
        if #available(iOS 26, *) {
            self
                .tabViewBottomAccessory { content }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self.overlay(alignment: .bottom) {
                FloatingMiniPlayer { content }
            }
        }
    }

    /// Keeps content clear of the floating mini player (before iOS 26 only).
    @ViewBuilder
    func miniPlayerInset() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            modifier(MiniPlayerInset())
        }
    }
}

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: Player

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, player.current == nil ? 0 : 66)
    }
}

private struct FloatingMiniPlayer<Content: View>: View {
    @EnvironmentObject private var player: Player
    @ViewBuilder var content: () -> Content

    var body: some View {
        if player.current != nil {
            content()
                .frame(height: 58)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .padding(.horizontal, 8)
                .padding(.bottom, 54)
        }
    }
}
