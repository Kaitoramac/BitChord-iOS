import Foundation

/// Time-synced lyrics from LRCLIB (lrclib.net, one of BitChord's providers):
/// free, keyless, and returns standard LRC.
struct Lyrics: Equatable {
    struct Line: Identifiable, Equatable {
        let id: Int
        let time: Double
        let text: String
    }

    /// Empty for plain (unsynced) lyrics.
    let lines: [Line]
    let plainText: String?

    var isSynced: Bool { !lines.isEmpty }

    /// The line playing at [time]: the last one that has started.
    func lineIndex(at time: Double) -> Int? {
        guard let first = lines.first, time >= first.time - 0.2 else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= time + 0.2 { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: Lyrics?] = [:]
    private let session = URLSession(configuration: .default)

    func lyrics(for song: Song, duration: Double) async -> Lyrics? {
        if let cached = cache[song.videoId] { return cached }
        let found = await fetch(song: song, duration: duration)
        cache[song.videoId] = found
        return found
    }

    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
    }

    private func fetch(song: Song, duration: Double) async -> Lyrics? {
        let title = Self.clean(song.title)
        let artist = song.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .trimmingCharacters(in: .whitespaces) ?? song.artist

        // Exact match first (title, artist, album, duration), then LRCLIB's search.
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album = song.album { components.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { components.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        if let url = components.url, let response: Response = await get(url), let lyrics = Self.lyrics(from: response) {
            return lyrics
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let url = search.url, let results: [Response] = await get(url) else { return nil }
        return results.lazy.compactMap { $0.syncedLyrics != nil ? Self.lyrics(from: $0) : nil }.first
            ?? results.lazy.compactMap(Self.lyrics(from:)).first
    }

    private func get<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("BitChord-iOS (https://github.com/kushagrasinghx/BitChord)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func lyrics(from response: Response) -> Lyrics? {
        if let synced = response.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return Lyrics(lines: lines, plainText: response.plainLyrics) }
        }
        if let plain = response.plainLyrics, !plain.isEmpty {
            return Lyrics(lines: [], plainText: plain)
        }
        return nil
    }

    /// `[mm:ss.xx] text` lines; a line may carry several timestamps.
    static func parseLRC(_ text: String) -> [Lyrics.Line] {
        let stamp = #/\[(\d+):(\d+(?:\.\d+)?)\]/#
        var entries: [(Double, String)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let matches = line.matches(of: stamp)
            guard !matches.isEmpty else { continue }
            let content = line.replacing(stamp, with: "").trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(match.output.1) ?? 0
                let seconds = Double(match.output.2) ?? 0
                entries.append((minutes * 60 + seconds, content))
            }
        }
        return entries.sorted { $0.0 < $1.0 }.enumerated().map { Lyrics.Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// "Song (Official Video) [Remastered 2011]" → "Song".
    private static func clean(_ title: String) -> String {
        var result = title
        for pattern in [#"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|remaster|mv)[^\)\]]*[\)\]]"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
