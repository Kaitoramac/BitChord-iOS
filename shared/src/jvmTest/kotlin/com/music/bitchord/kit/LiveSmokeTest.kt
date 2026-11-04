package com.music.bitchord.kit

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Hits YouTube Music for real: `BITCHORD_LIVE=1 ./gradlew :shared:jvmTest`.
 * Skipped otherwise, so the normal build stays offline. No PO token host on
 * the JVM, so this exercises the token-free clients, as the app's fallback does.
 */
class LiveSmokeTest {
    private val live = System.getenv("BITCHORD_LIVE") == "1"

    private val store = object : KeyValueStore {
        private val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String?) {
            if (value == null) map.remove(key) else map[key] = value
        }
    }

    private val logger = object : KitLogger {
        override fun log(level: String, tag: String, message: String) = println("[$level] $tag: $message")
    }

    @Test
    fun searchesAndResolvesAStream() {
        if (!live) return
        runBlocking {
            val service = MusicService(store, javaScriptHost = null, language = "en", region = "FR", logger = logger)
            service.setDebugLogging(true)

            val home = service.home()
            println("home: ${home.shelves.size} shelves, first: ${home.shelves.firstOrNull()?.title}")
            assertTrue(home.shelves.isNotEmpty(), "home has shelves")

            val results = service.search("daft punk around the world", SearchScope.SONGS)
            val track = results.songs.first()
            println("search: ${track.title} by ${track.artist} (${track.videoId})")

            val stream = service.resolveStream(track.videoId, emptyList())
            println("stream: ${stream.clientName} ${stream.mimeType} ${stream.bitrateKbps}kbps bounded=${stream.requiresBoundedRange}")
            assertTrue(stream.url.startsWith("https://"), "stream URL")
            assertTrue(stream.mimeType.orEmpty().startsWith("audio/mp4"), "AAC in MP4")

            track.albumId?.let { albumId ->
                val album = service.collection(albumId)
                println("album: ${album.title} - ${album.tracks.size} tracks")
                assertTrue(album.tracks.isNotEmpty(), "album has tracks")
            }
        }
    }
}
