import SwiftUI

enum Theme {
    /// The red-pink accent of the music app family.
    static let accent = Color("AccentColor")
    static let cardWidth: CGFloat = 170
    static let artworkRadius: CGFloat = 8
}

// MARK: - Artwork

struct ArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = Theme.artworkRadius
    var circle = false
    /// Width over height: 1 for album art, 16/9 for video thumbnails.
    var aspectRatio: CGFloat = 1

    @State private var image: UIImage?

    private var shape: AnyShape {
        circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    var body: some View {
        // The frame is set by the colour's aspect ratio; the picture fills it and is clipped.
        Color(.secondarySystemFill)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: circle ? "music.mic" : "music.note")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(shape)
            .overlay { shape.stroke(.primary.opacity(0.08), lineWidth: 0.5) }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ImageLoader.shared.cachedImage(for: url) {
                image = cached
                return
            }
            let loaded = await ImageLoader.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

// MARK: - Cards

/// A square card: artwork over a title and a subtitle (circle for artists).
struct CardView: View {
    let card: Card
    var width: CGFloat = Theme.cardWidth

    var body: some View {
        VStack(alignment: card.kind == .artist ? .center : .leading, spacing: 6) {
            ArtworkImage(url: card.artworkURL, circle: card.kind == .artist)
                .frame(width: width, height: width)
            VStack(alignment: card.kind == .artist ? .center : .leading, spacing: 1) {
                Text(card.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if card.kind != .artist, !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, alignment: card.kind == .artist ? .center : .leading)
        }
    }
}

struct VideoCardView: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(url: card.artworkURL, aspectRatio: 16 / 9)
                .frame(width: 280)
            Text(card.title).font(.subheadline).lineLimit(1)
            Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 280, alignment: .leading)
    }
}

/// Wraps a card so a tap plays it or opens its page, with the usual long-press menu.
struct CardLink<Label: View>: View {
    let card: Card
    @ViewBuilder var label: () -> Label

    @EnvironmentObject private var player: Player

    var body: some View {
        Group {
            if let route = card.route {
                NavigationLink(value: route) { label() }
            } else {
                Button {
                    if let song = card.song { player.play(song) }
                } label: { label() }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { CardMenu(card: card) }
    }
}

struct CardMenu: View {
    let card: Card

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let song = card.song {
            SongMenu(song: song)
        } else {
            if card.kind != .artist {
                Button { app.play(card, shuffled: false) } label: { Label("Play", systemImage: "play") }
                Button { app.play(card, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                Button { app.enqueue(card, next: true) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { app.enqueue(card, next: false) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
                Divider()
            }
            Button { library.toggle(card) } label: {
                library.contains(card)
                    ? Label("Remove from Library", systemImage: "minus.circle")
                    : Label("Add to Library", systemImage: "plus")
            }
        }
    }
}

struct SongMenu: View {
    let song: Song

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Button { player.playNext([song]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue([song]) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Button { player.startRadio(from: song) } label: { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
        Divider()
        Button { library.toggle(song) } label: {
            library.contains(song)
                ? Label("Remove from Library", systemImage: "minus.circle")
                : Label("Add to Library", systemImage: "plus")
        }
        if let albumId = song.albumId {
            Button { app.open(.collection(albumId)) } label: { Label("Go to Album", systemImage: "square.stack") }
        }
        if let artistId = song.artistId {
            Button { app.open(.artist(artistId)) } label: { Label("Go to Artist", systemImage: "music.mic") }
        }
        ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(song.videoId)")!) {
            Label("Share Song…", systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Song rows

struct SongRow: View {
    let song: Song
    /// Albums show track numbers instead of artwork.
    var number: Int?
    var showsArtist = true
    var isCurrent = false

    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Group {
                    if isCurrent {
                        NowPlayingBars(animating: player.isPlaying)
                    } else {
                        Text("\(number)").foregroundStyle(.secondary)
                    }
                }
                .font(.callout.monospacedDigit())
                .frame(width: 24)
            } else {
                ArtworkImage(url: song.artworkURL, cornerRadius: 4)
                    .frame(width: 48, height: 48)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4))
                            NowPlayingBars(animating: player.isPlaying).foregroundStyle(.white)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(song.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    if song.isVideo {
                        Image(systemName: "play.rectangle.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if showsArtist {
                    Text(song.artist)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Menu {
                SongMenu(song: song)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .contextMenu { SongMenu(song: song) }
    }
}

/// The little equaliser shown on the playing row.
struct NowPlayingBars: View {
    var animating: Bool

    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animating)
            .foregroundStyle(Theme.accent)
    }
}

// MARK: - Shelves

struct ShelfHeader: View {
    let title: String
    var subtitle: String = ""
    var route: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !subtitle.isEmpty {
                Text(subtitle.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(title).font(.title2.bold())
                if route != nil {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }
}

struct ShelfView: View {
    let shelf: ShelfModel

    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: shelf.title, subtitle: shelf.subtitle)
            switch shelf.layout {
            case .cards:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(shelf.cards) { card in
                            CardLink(card: card) { CardView(card: card) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                }
                .scrollTargetBehavior(.viewAligned)
            case .video:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(shelf.cards) { card in
                            CardLink(card: card) { VideoCardView(card: card) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                }
                .scrollTargetBehavior(.viewAligned)
            case .list:
                SongColumns(songs: shelf.cards.compactMap(\.song))
            }
        }
    }
}

/// Songs paged horizontally in columns of four, like "Top Songs".
struct SongColumns: View {
    let songs: [Song]

    @EnvironmentObject private var player: Player

    var body: some View {
        let columns = stride(from: 0, to: songs.count, by: 4).map { Array(songs[$0..<min($0 + 4, songs.count)]) }
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(columns.indices, id: \.self) { column in
                    VStack(spacing: 0) {
                        ForEach(columns[column]) { song in
                            Button {
                                let start = songs.firstIndex(of: song) ?? 0
                                player.play(songs, startAt: start)
                            } label: {
                                SongRow(song: song, isCurrent: player.current == song)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            if song != columns[column].last { Divider().padding(.leading, 60) }
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in width - 56 }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - Buttons and states

/// Apple Music's pair of grey capsules under a header: Play and Shuffle.
struct PlayShuffleButtons: View {
    var play: () -> Void
    var shuffle: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .font(.body.weight(.semibold))
        .buttonStyle(CapsuleButtonStyle())
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 13)
            .foregroundStyle(Theme.accent)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct LoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 300)
    }
}

struct ErrorView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry).buttonStyle(.bordered)
        }
        .frame(minHeight: 300)
    }
}

/// The state of a page that loads from the network.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
