import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: player.current?.artworkURL, cornerRadius: 6)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let artist = player.current?.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if player.isLoading {
                    ProgressView()
                        .frame(width: 36, height: 36)
                } else {
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                Button(action: player.next) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if player.current != nil { app.showsNowPlaying = true }
        }
    }
}
