import SwiftUI
import AVKit
import MediaPlayer

/// The full-screen player: artwork-coloured animated background, big artwork
/// that shrinks on pause, scrubber, transport, volume, and the lyrics and
/// queue views behind the bottom buttons.
struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .artwork
    @State private var palette: [Color] = []
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MeshBackground(colors: palette)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    switch mode {
                    case .artwork:
                        bigArtwork(width: geometry.size.width - 56)
                        titleRow
                            .padding(.top, 8)
                    case .lyrics:
                        compactHeader
                        LyricsView()
                            .frame(maxHeight: .infinity)
                    case .queue:
                        compactHeader
                        QueueView()
                            .frame(maxHeight: .infinity)
                    }

                    Scrubber()
                        .padding(.top, 18)
                    TransportControls()
                        .padding(.vertical, mode == .artwork ? 22 : 14)
                    VolumeRow()
                    bottomBar
                        .padding(.top, 18)
                        .padding(.bottom, 4)
                }
                .padding(.horizontal, 28)
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: dragOffset > 0 ? 40 : 0, style: .continuous))
            .offset(y: dragOffset)
            .gesture(dismissDrag)
        }
        .presentationBackground(.clear)
        .task(id: player.current?.artworkURL) { await loadPalette() }
        .onChange(of: player.current == nil) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    // MARK: Pieces

    private func bigArtwork(width: CGFloat) -> some View {
        ArtworkImage(url: player.current?.artworkURL, cornerRadius: 12)
            .frame(width: width, height: width)
            .scaleEffect(player.isPlaying || player.isLoading ? 1 : 0.82)
            .shadow(color: .black.opacity(player.isPlaying ? 0.35 : 0.2), radius: player.isPlaying ? 28 : 14, y: 14)
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
            .frame(maxHeight: .infinity)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Button {
                    if let artistId = player.current?.artistId { app.open(.artist(artistId)) }
                } label: {
                    Text(player.current?.artist ?? "")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let song = player.current {
                Button { library.toggle(song) } label: {
                    Image(systemName: library.contains(song) ? "star.fill" : "star")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                Menu { SongMenu(song: song) } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.12), in: Circle())
                }
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: player.current?.artworkURL, cornerRadius: 6)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .onTapGesture { withAnimation(.spring) { mode = .artwork } }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let song = player.current {
                Menu { SongMenu(song: song) } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.12), in: Circle())
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var bottomBar: some View {
        HStack {
            modeButton(.lyrics, symbol: "quote.bubble", activeSymbol: "quote.bubble.fill")
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 44)
            Spacer()
            modeButton(.queue, symbol: "list.bullet", activeSymbol: "list.bullet")
        }
        .padding(.horizontal, 24)
    }

    private func modeButton(_ target: Mode, symbol: String, activeSymbol: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                mode = mode == target ? .artwork : target
            }
        } label: {
            Image(systemName: mode == target ? activeSymbol : symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .foregroundStyle(mode == target ? Color.black : Color.white.opacity(0.75))
                .background {
                    if mode == target { Circle().fill(.white.opacity(0.9)).frame(width: 36, height: 36) }
                }
        }
        .buttonStyle(.plain)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard mode == .artwork || value.startLocation.y < 140 else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if dragOffset > 140 || value.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragOffset = 0 }
                }
            }
    }

    private func loadPalette() async {
        guard let url = player.current?.artworkURL else {
            palette = []
            return
        }
        let colors = await ImageLoader.shared.palette(for: url)
        withAnimation(.easeInOut(duration: 0.8)) { palette = colors.map { Color(uiColor: $0) } }
    }
}

// MARK: - Background

/// A slowly moving 3×3 mesh of the artwork's colours (iOS 18 MeshGradient).
struct MeshBackground: View {
    let colors: [Color]

    var body: some View {
        let fill = colors.count == 9 ? colors : Array(repeating: Color(white: 0.22), count: 9)
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [Float(0.5 + 0.18 * sin(t * 0.21)), Float(0.5 + 0.16 * cos(t * 0.17))], [1, 0.5],
                    [0, 1], [Float(0.5 + 0.12 * sin(t * 0.13)), 1], [1, 1],
                ],
                colors: fill,
                smoothsColors: true
            )
        }
        .overlay(Color.black.opacity(0.18))
    }
}

// MARK: - Scrubber

struct Scrubber: View {
    @EnvironmentObject private var player: Player
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let value = dragValue ?? player.currentTime
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let fraction = min(max(value / duration, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(dragValue == nil ? 0.75 : 1))
                        .frame(width: geometry.size.width * fraction)
                }
                .frame(height: dragValue == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let fraction = min(max(drag.location.x / geometry.size.width, 0), 1)
                            withAnimation(.spring(response: 0.25)) { dragValue = fraction * duration }
                        }
                        .onEnded { _ in
                            if let target = dragValue { player.seek(to: target) }
                            withAnimation(.spring(response: 0.3)) { dragValue = nil }
                        }
                )
            }
            .frame(height: 20)
            .scaleEffect(x: dragValue == nil ? 1 : 1.03, y: 1)

            HStack {
                Text(Self.format(value))
                Spacer()
                if let info = player.streamInfo {
                    Text(info.components(separatedBy: " · ").prefix(2).joined(separator: " · "))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Text("-" + Self.format(max(player.duration - value, 0)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Transport

struct TransportControls: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack {
            Spacer()
            Button(action: player.previous) {
                Image(systemName: "backward.fill").font(.system(size: 34))
            }
            Spacer()
            Button(action: player.togglePlayPause) {
                ZStack {
                    if player.isLoading {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 52))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 80, height: 70)
            }
            Spacer()
            Button(action: player.next) {
                Image(systemName: "forward.fill").font(.system(size: 34))
            }
            Spacer()
        }
        .buttonStyle(PressedScaleStyle())
    }
}

struct PressedScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.15 : 0))
                    .frame(width: 76, height: 76)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Volume and AirPlay

struct VolumeRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption)
            SystemVolumeSlider()
                .frame(height: 34)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// The system volume, through MPVolumeView (the only public way to set it).
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white.withAlphaComponent(0.75)
            slider.maximumTrackTintColor = .white.withAlphaComponent(0.22)
            slider.setThumbImage(Self.thumb(), for: .normal)
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    private static func thumb() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 10, height: 10))
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = UIColor(named: "AccentColor") ?? .systemPink
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
