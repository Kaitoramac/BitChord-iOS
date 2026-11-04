import SwiftUI

// MARK: - Lyrics

/// Synced lyrics in big type: the current line lit, the rest dimmed, following
/// the song; tap a line to jump there.
struct LyricsView: View {
    @EnvironmentObject private var player: Player

    @State private var lyrics: Lyrics?
    @State private var loading = true
    @State private var userScrolledAt: Date?

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics, lyrics.isSynced {
                synced(lyrics)
            } else if let text = lyrics?.plainText {
                ScrollView(showsIndicators: false) {
                    Text(text)
                        .font(.title2.weight(.bold))
                        .lineSpacing(8)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                }
            } else {
                ContentUnavailableView("No Lyrics", systemImage: "quote.bubble", description: Text("Lyrics aren't available for this song."))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.06),
            .init(color: .black, location: 0.9), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        .task(id: player.current?.videoId) {
            guard let song = player.current else { return }
            loading = true
            lyrics = await LyricsService.shared.lyrics(for: song, duration: player.duration > 0 ? player.duration : song.durationSeconds ?? 0)
            loading = false
        }
    }

    private func synced(_ lyrics: Lyrics) -> some View {
        let currentIndex = lyrics.lineIndex(at: player.currentTime)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(lyrics.lines) { line in
                        let isCurrent = line.id == currentIndex
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.32))
                            .blur(radius: isCurrent || userScrolledAt != nil ? 0 : 0.6)
                            .scaleEffect(isCurrent ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: line.time) }
                            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isCurrent)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 120)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
            .onChange(of: currentIndex) { _, index in
                guard let index else { return }
                // Leave the reader alone for a few seconds after they scroll by hand.
                if let touched = userScrolledAt, Date().timeIntervalSince(touched) < 4 { return }
                userScrolledAt = nil
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
        }
    }
}

// MARK: - Queue

/// "Playing Next": shuffle, repeat and autoplay, then the upcoming songs,
/// reorderable and removable.
struct QueueView: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                toggle("shuffle", isOn: player.isShuffled, action: player.toggleShuffle)
                toggle(player.repeatMode == .one ? "repeat.1" : "repeat", isOn: player.repeatMode != .off, action: player.cycleRepeat)
                toggle("infinity", isOn: player.autoplay) { player.autoplay.toggle() }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Playing Next").font(.headline)
                Spacer()
                if player.autoplay {
                    Text("Autoplay").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }

            List {
                ForEach(Array(player.upcoming.enumerated()), id: \.offset) { offset, song in
                    Button {
                        player.skip(toUpcoming: offset)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkImage(url: song.artworkURL, cornerRadius: 4)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).lineLimit(1)
                                Text(song.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.15))
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
                .onMove(perform: player.moveUpcoming)
                .onDelete(perform: player.removeUpcoming)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .overlay {
                if player.upcoming.isEmpty {
                    Text("Nothing up next").foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func toggle(_ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .background(isOn ? Color.white.opacity(0.9) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
