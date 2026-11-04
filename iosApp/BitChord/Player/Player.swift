import AVFoundation
import MediaPlayer
import UIKit
import BitChordKit

/// The music player: queue, playback, lock-screen controls.
///
/// Built on AVQueuePlayer holding the current track and, once resolved, the
/// next one, so tracks follow each other without a gap. Each stream URL comes
/// from InnerTubeX; if AVPlayer cannot open it, the track is resolved again
/// with that YouTube client excluded, as BitChord does on Android.
@MainActor
final class Player: ObservableObject {
    enum RepeatMode: String, Codable {
        case off, all, one
    }

    @Published private(set) var queue: [Song] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isShuffled = false
    @Published var repeatMode: RepeatMode = .off { didSet { queueChanged() } }
    @Published var autoplay = true { didSet { save() } }
    @Published var errorMessage: String?
    /// "AAC · 128 kbps · IOS", for the curious.
    @Published private(set) var streamInfo: String?

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upcoming: ArraySlice<Song> { queue.indices.contains(index + 1) ? queue[(index + 1)...] : [] }
    var history: ArraySlice<Song> { queue.indices.contains(index) ? queue[..<index] : [] }

    private let catalog: CatalogService
    private let library: LibraryStore
    private let player = AVQueuePlayer()
    private var unshuffledOrder: [Song]?
    private var streams: [String: (stream: PlayableStream, resolvedAt: Date)] = [:]
    private var loadTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var autoplayTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemStatusObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var sessionActive = false

    init(catalog: CatalogService, library: LibraryStore) {
        self.catalog = catalog
        self.library = library
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        observePlayer()
        setUpRemoteCommands()
        restore()
    }

    // MARK: - Starting playback

    /// Replaces the queue with [songs] and plays from [startIndex].
    func play(_ songs: [Song], startAt startIndex: Int = 0, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        var list = songs
        var start = min(max(startIndex, 0), songs.count - 1)
        unshuffledOrder = nil
        isShuffled = false
        if shuffled {
            unshuffledOrder = songs
            let first = shuffled && startIndex == 0 ? songs.randomElement()! : songs[start]
            list = [first] + songs.filter { $0 != first }.shuffled()
            start = 0
            isShuffled = true
        }
        queue = list
        index = start
        startCurrent()
    }

    func play(_ song: Song) {
        play([song])
    }

    /// Plays a song followed by YouTube Music's radio for it.
    func startRadio(from song: Song) {
        play([song])
        autoplay = true
        extendWithAutoplay(force: true)
    }

    func playNext(_ songs: [Song]) {
        guard current != nil else { return play(songs) }
        let fresh = songs.filter { song in !upcoming.contains(song) }
        queue.insert(contentsOf: fresh, at: index + 1)
        queueChanged()
    }

    func addToQueue(_ songs: [Song]) {
        guard current != nil else { return play(songs) }
        queue.append(contentsOf: songs)
        queueChanged()
    }

    func removeUpcoming(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 })
        queue.remove(atOffsets: absolute)
        queueChanged()
    }

    func moveUpcoming(from source: IndexSet, to destination: Int) {
        var upcomingSongs = Array(upcoming)
        upcomingSongs.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange((index + 1)..., with: upcomingSongs)
        queueChanged()
    }

    /// Jumps to an entry of the upcoming list.
    func skip(toUpcoming offset: Int) {
        let target = index + 1 + offset
        guard queue.indices.contains(target) else { return }
        index = target
        startCurrent()
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        if player.currentItem == nil {
            startCurrent()
            return
        }
        activateSession()
        player.play()
    }

    func pause() {
        player.pause()
        save()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            if let nextItem = player.items().dropFirst().first as? SongItem, nextItem.song == queue[index + 1] {
                player.advanceToNextItem() // currentItem KVO moves the index
            } else {
                index += 1
                startCurrent()
            }
        } else if repeatMode == .all {
            index = 0
            startCurrent()
        } else {
            player.pause()
            player.seek(to: .zero)
        }
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            startCurrent()
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlayingTime() }
        }
    }

    func toggleShuffle() {
        guard current != nil else { return }
        if isShuffled, let original = unshuffledOrder, let song = current {
            // Back to the original order, from the current song onwards.
            let played = Set(history.map(\.videoId))
            let rest = original.drop { $0 != song }.dropFirst().filter { !played.contains($0.videoId) }
            queue = Array(history) + [song] + rest
            unshuffledOrder = nil
            isShuffled = false
        } else {
            unshuffledOrder = queue
            queue = Array(queue[...index]) + upcoming.shuffled()
            isShuffled = true
        }
        queueChanged()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Loading tracks

    private func startCurrent() {
        loadTask?.cancel()
        prepareTask?.cancel()
        guard let song = current else { return }
        player.removeAllItems()
        currentTime = 0
        duration = song.durationSeconds ?? 0
        isLoading = true
        errorMessage = nil
        streamInfo = nil
        updateNowPlaying()
        save()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await self.makeItem(for: song)
                guard !Task.isCancelled, self.current == song else { return }
                self.player.insert(item, after: nil)
                self.activateSession()
                self.player.play()
                self.didBecomeCurrent(item)
                self.prepareNext()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.errorMessage = "Couldn't play “\(song.title)”: \(error.localizedDescription)"
            }
        }
    }

    /// Queues the next track behind the current one so it starts without a gap.
    private func prepareNext() {
        prepareTask?.cancel()
        // Drop a prepared item that is no longer what comes next.
        for item in player.items().dropFirst() {
            if let item = item as? SongItem, upcoming.first == item.song, repeatMode != .one { continue }
            player.remove(item)
        }
        guard repeatMode != .one, let next = upcoming.first, player.items().count < 2 else {
            extendWithAutoplay()
            return
        }
        prepareTask = Task { [weak self] in
            guard let self else { return }
            guard let item = try? await self.makeItem(for: next), !Task.isCancelled else { return }
            guard self.upcoming.first == next, let currentItem = self.player.currentItem, self.player.items().count == 1 else { return }
            self.player.insert(item, after: currentItem)
        }
        extendWithAutoplay()
    }

    private func makeItem(for song: Song, excluding profiles: [String] = []) async throws -> SongItem {
        let stream = try await stream(for: song.videoId, excluding: profiles)
        guard let url = URL(string: stream.url) else { throw URLError(.badURL) }
        let loader = ChunkedResourceLoader(
            url: url,
            headers: stream.headers,
            chunkSize: stream.requiresBoundedRange ? stream.rangeChunkSizeBytes : 4 * 1024 * 1024,
            contentLength: stream.contentLengthBytes?.int64Value
        )
        let asset = AVURLAsset(url: loader.assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = SongItem(asset: asset, song: song, stream: stream, loader: loader)
        item.preferredForwardBufferDuration = 30
        if UserDefaults.standard.object(forKey: "normalizeVolume") as? Bool ?? true {
            await item.applyLoudnessNormalization()
        }
        return item
    }

    private func stream(for videoId: String, excluding profiles: [String]) async throws -> PlayableStream {
        if profiles.isEmpty, let cached = streams[videoId], isFresh(cached.stream, resolvedAt: cached.resolvedAt) {
            return cached.stream
        }
        let stream = try await catalog.stream(for: videoId, excluding: profiles)
        streams[videoId] = (stream, Date())
        if streams.count > 50, let oldest = streams.min(by: { $0.value.resolvedAt < $1.value.resolvedAt })?.key {
            streams.removeValue(forKey: oldest)
        }
        return stream
    }

    private func isFresh(_ stream: PlayableStream, resolvedAt: Date) -> Bool {
        if let expiry = stream.expiresAtEpochSeconds?.int64Value {
            return Date(timeIntervalSince1970: TimeInterval(expiry)) > Date().addingTimeInterval(10 * 60)
        }
        return Date().timeIntervalSince(resolvedAt) < 3 * 3600
    }

    /// AVPlayer refused the URL: resolve again without that client, at most twice.
    private func recover(from item: SongItem) {
        // Both the status KVO and the failure notification can report the same item.
        guard !item.isRecovering else { return }
        item.isRecovering = true
        guard item.song == current, item.attempts < 2 else {
            isLoading = false
            errorMessage = "Couldn't play “\(item.song.title)”."
            return
        }
        let song = item.song
        let excluded = item.excludedProfiles + [item.stream.profileId]
        let position = currentTime
        streams.removeValue(forKey: song.videoId)
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let replacement = try await self.makeItem(for: song, excluding: excluded)
                replacement.attempts = item.attempts + 1
                replacement.excludedProfiles = excluded
                guard !Task.isCancelled, self.current == song else { return }
                self.player.removeAllItems()
                self.player.insert(replacement, after: nil)
                if position > 1 { _ = await replacement.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
                self.player.play()
                self.didBecomeCurrent(replacement)
                self.prepareNext()
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.errorMessage = "Couldn't play “\(song.title)”: \(error.localizedDescription)"
            }
        }
    }

    /// Appends YouTube Music's own continuation when the queue runs low (the ∞ toggle).
    private func extendWithAutoplay(force: Bool = false) {
        guard autoplay || force, repeatMode == .off, let last = queue.last, upcoming.count < 3, autoplayTask == nil else { return }
        autoplayTask = Task { [weak self] in
            guard let self else { return }
            defer { self.autoplayTask = nil }
            guard let more = try? await self.catalog.upNext(after: last.videoId), !Task.isCancelled else { return }
            let known = Set(self.queue.map(\.videoId))
            let fresh = more.filter { !known.contains($0.videoId) }.prefix(25)
            guard !fresh.isEmpty, self.queue.last == last else { return }
            self.queue.append(contentsOf: fresh)
            self.queueChanged()
        }
    }

    private func queueChanged() {
        if repeatMode == .one {
            for item in player.items().dropFirst() { player.remove(item) }
        }
        if player.currentItem != nil { prepareNext() }
        save()
    }

    // MARK: - Observing AVPlayer

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
            }
        }

        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = status == .playing || status == .waitingToPlayAtSpecifiedRate
                if status == .playing { self.isLoading = false }
                self.updateNowPlayingTime()
            }
        })

        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem as? SongItem
            Task { @MainActor in self?.currentItemChanged(to: item) }
        })

        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? SongItem
            MainActor.assumeIsolated { self?.itemFinished(item) }
        })
        notifications.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? SongItem
            MainActor.assumeIsolated { if let item { self?.recover(from: item) } }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        })
        notifications.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        })
    }

    private func didBecomeCurrent(_ item: SongItem) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.recover(from: item) }
        }
        let stream = item.stream
        let format = (stream.mimeType ?? "").contains("mp4a") || (stream.mimeType ?? "").contains("audio/mp4") ? "AAC" : (stream.mimeType ?? "Audio")
        streamInfo = "\(format) · \(stream.bitrateKbps) kbps · \(stream.clientName)"
        library.recordPlay(item.song)
        updateNowPlaying()
    }

    /// AVQueuePlayer moved on to the item we prepared: follow it in the queue.
    private func currentItemChanged(to item: SongItem?) {
        guard let item else { return }
        if item.song != current, let position = queue.indices.dropFirst(index).first(where: { queue[$0] == item.song }) {
            index = position
            currentTime = 0
            duration = item.song.durationSeconds ?? 0
            didBecomeCurrent(item)
            prepareNext()
            save()
        }
    }

    private func itemFinished(_ item: SongItem?) {
        guard let item, item.song == current else { return }
        if repeatMode == .one {
            player.seek(to: .zero)
            player.play()
            return
        }
        // The next item, if prepared, starts by itself; otherwise load it now.
        if player.items().count <= 1 {
            if index + 1 < queue.count {
                index += 1
                startCurrent()
            } else if repeatMode == .all, !queue.isEmpty {
                index = 0
                startCurrent()
            }
        }
    }

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended,
           let options = info?[AVAudioSessionInterruptionOptionKey] as? UInt,
           AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            player.play()
        }
    }

    private func activateSession() {
        guard !sessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        } catch {
            errorMessage = "Audio session unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: - Lock screen and Control Center

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let song = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkTask?.cancel()
        guard let url = song.artworkURL else { return }
        artworkTask = Task { [weak self] in
            guard let image = await ImageLoader.shared.image(for: url), !Task.isCancelled else { return }
            guard let self, self.current == song else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.nowPlayingArtwork = artwork
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func updateNowPlayingTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Saved queue

    private struct SavedState: Codable {
        var queue: [Song]
        var index: Int
        var time: Double
        var repeatMode: RepeatMode
        var autoplay: Bool
    }

    private static let saveKey = "player.state"

    private func save() {
        let state = SavedState(queue: Array(queue.prefix(500)), index: index, time: currentTime, repeatMode: repeatMode, autoplay: autoplay)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.saveKey)
        }
    }

    /// Brings back the last queue, paused, as Apple Music does after a relaunch.
    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.saveKey),
              let state = try? JSONDecoder().decode(SavedState.self, from: data),
              state.queue.indices.contains(state.index) else { return }
        queue = state.queue
        index = state.index
        repeatMode = state.repeatMode
        autoplay = state.autoplay
        currentTime = state.time
        duration = current?.durationSeconds ?? 0
    }
}

/// An AVPlayerItem that knows which song it plays and which stream it came from.
final class SongItem: AVPlayerItem {
    let song: Song
    let stream: PlayableStream
    let loader: ChunkedResourceLoader
    var attempts = 0
    var excludedProfiles: [String] = []
    var isRecovering = false

    init(asset: AVURLAsset, song: Song, stream: PlayableStream, loader: ChunkedResourceLoader) {
        self.song = song
        self.stream = stream
        self.loader = loader
        super.init(asset: asset, automaticallyLoadedAssetKeys: ["duration", "playable"])
    }

    /// YouTube's loudness value says how far the track sits above its target;
    /// turn loud masters down to it (never up, which would clip).
    func applyLoudnessNormalization() async {
        guard let loudness = stream.loudnessDb?.doubleValue, loudness > 0,
              let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
        let gain = Float(pow(10, -loudness / 20))
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(max(gain, 0.1), at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        audioMix = mix
    }
}
