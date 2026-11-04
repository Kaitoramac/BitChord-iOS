@file:OptIn(kotlin.time.ExperimentalTime::class)

package com.music.bitchord.kit

import com.metrolist.innertubex.InnerTube
import com.metrolist.innertubex.InnerTubeLogLevel
import com.metrolist.innertubex.InnerTubeLogger
import com.metrolist.innertubex.cipher.PlayerConfigRepository
import com.metrolist.innertubex.cipher.RemotePlayerConfigStore
import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.extraction.AudioQuality
import com.metrolist.innertubex.extraction.ContentHints
import com.metrolist.innertubex.extraction.ExtractedStream
import com.metrolist.innertubex.extraction.InnerTubeExtractor
import com.metrolist.innertubex.extraction.YtConfigParserImpl
import com.metrolist.innertubex.extraction.generateClientPlaybackNonce
import com.metrolist.innertubex.models.YouTubeClient
import com.metrolist.innertubex.models.YouTubeLocale
import com.music.bitchord.data.innertube.InnertubeParser
import com.music.bitchord.data.model.SearchFilter
import com.music.bitchord.data.model.SearchResult
import com.music.bitchord.kit.potoken.BotGuardTokenProvider
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** Thrown to Swift with a message fit to show. */
class MusicServiceException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** A browse category tile (Search tab → "Browse Categories"). Not `Category`: that name is an Objective-C runtime type. */
class BrowseCategory(
    val title: String,
    val browseId: String,
    val params: String?,
    /** 0xAARRGGBB, when YouTube gives the tile a colour. */
    val color: Long?,
    val artworkUrl: String?,
)

class TrackPage(val tracks: List<Track>, val continuation: String?)

enum class SearchScope { ALL, SONGS, ALBUMS, ARTISTS, PLAYLISTS, VIDEOS }

/**
 * Everything the iOS app asks of YouTube Music, behind one object.
 *
 * Catalogue requests go through InnerTubeX's [InnerTube] as the WEB_REMIX
 * client and are read by BitChord's own [InnertubeParser], so pages come out
 * exactly as the Android app sees them. Streams come from InnerTubeX's
 * extractor, asked for AAC in MP4: the one audio format AVPlayer plays
 * directly (the Opus/WebM formats Android prefers are not playable on iOS).
 *
 * Every suspend function is exported to Swift as `async throws`.
 */
class MusicService(
    private val store: KeyValueStore,
    javaScriptHost: JavaScriptHost?,
    language: String,
    region: String,
    logger: KitLogger? = null,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        encodeDefaults = true
    }

    private val http = platformHttpClient {
        install(ContentNegotiation) { json(json) }
        install(HttpTimeout) {
            requestTimeoutMillis = 30_000
            connectTimeoutMillis = 15_000
            socketTimeoutMillis = 20_000
        }
        expectSuccess = false
    }

    private val itxLogger = InnerTubeLogger { event ->
        val details = if (event.details.isEmpty()) "" else event.details.entries.joinToString(prefix = " [", postfix = "]") { "${it.key}=${it.value}" }
        val line = "${event.message}$details"
        when (event.level) {
            InnerTubeLogLevel.DEBUG -> KitLog.d("ITX ${event.tag}", line)
            InnerTubeLogLevel.INFO -> KitLog.d("ITX ${event.tag}", line)
            InnerTubeLogLevel.WARN -> KitLog.w("ITX ${event.tag}", line)
            InnerTubeLogLevel.ERROR -> KitLog.e("ITX ${event.tag}", line)
        }
    }

    /** The remote cipher hints InnerTubeX reads, cached in [store] between launches. */
    private val playerConfigs = object : PlayerConfigRepository {
        override val enabled: Boolean = true
        override val sourceUrl: String = PLAYER_CONFIG_URL
        override val defaultSourceUrl: String = PLAYER_CONFIG_URL
        override var cachedJson: String
            get() = store.getString("itx.json").orEmpty()
            set(value) = store.putString("itx.json", value)
        override var cachedAtMs: Long
            get() = store.getString("itx.cachedAtMs")?.toLongOrNull() ?: 0L
            set(value) = store.putString("itx.cachedAtMs", value.toString())
        override var cachedSourceUrl: String
            get() = store.getString("itx.sourceUrl").orEmpty()
            set(value) = store.putString("itx.sourceUrl", value)
        override var cachedEtag: String
            get() = store.getString("itx.etag").orEmpty()
            set(value) = store.putString("itx.etag", value)
    }

    private val innerTube = InnerTube(http, logger = itxLogger)
    private val configStore = RemotePlayerConfigStore(http, playerConfigs, itxLogger)
    private val cipher = YouTubeCipherService(http, configStore, itxLogger)
    private val extractor = InnerTubeExtractor(
        configParser = YtConfigParserImpl(http, innerTube, configStore, itxLogger, cipherService = cipher),
        cipherService = cipher,
        innerTube = innerTube,
        tokenProvider = javaScriptHost?.let { BotGuardTokenProvider(it, http) },
        logger = itxLogger,
    )

    private val sessionLock = Mutex()

    init {
        logger?.let { KitLog.sink = it }
        innerTube.locale = YouTubeLocale(gl = region.uppercase(), hl = language)
        innerTube.visitorData = store.getString(VISITOR_DATA_KEY)
    }

    /** Verbose logging of InnerTubeX's client selection and the PO token flow. */
    fun setDebugLogging(enabled: Boolean) {
        KitLog.debug = enabled
    }

    // ---------------------------------------------------------------- session

    /**
     * Visitor data identifies an anonymous session to YouTube; every request
     * carries it. Fetched once and kept, as the official clients do.
     */
    private suspend fun ensureSession() {
        if (innerTube.visitorData != null) return
        sessionLock.withLock {
            if (innerTube.visitorData != null) return
            val fresh = innerTube.fetchFreshVisitorData()
            if (fresh != null) {
                innerTube.visitorData = fresh
                store.putString(VISITOR_DATA_KEY, fresh)
            }
        }
    }

    /** Fetches the player configuration and compiles the cipher ahead of the first play. */
    @Throws(Throwable::class)
    suspend fun warmUp() = call("warm-up") {
        ensureSession()
        extractor.prewarm()
    }

    // ---------------------------------------------------------------- browse

    @Throws(Throwable::class)
    suspend fun home(): HomePage = call("home") {
        val response = browse("FEmusic_home")
        HomePage(
            shelves = InnertubeParser.parseHome(response).map(Shelf::from).filter { it.items.isNotEmpty() },
            continuation = InnertubeParser.continuationToken(response),
        )
    }

    /** The next shelves of Home, as the official app loads them while scrolling. */
    @Throws(Throwable::class)
    suspend fun homeContinuation(token: String): HomePage = call("home:more") {
        val response = browseContinuation(token)
        HomePage(
            shelves = InnertubeParser.parseHomeContinuation(response).map(Shelf::from).filter { it.items.isNotEmpty() },
            continuation = InnertubeParser.continuationToken(response),
        )
    }

    /** New releases, charts and the rest of YouTube Music's Explore page (the "New" tab). */
    @Throws(Throwable::class)
    // Not `newReleases`: Objective-C reserves the `new…` method family, and Kotlin/Native would export it as `doNewReleases`.
    suspend fun latestReleases(): List<Shelf> = call("new") {
        coroutineScope {
            val releases = async { shelvesOf("FEmusic_new_releases") }
            val explore = async { shelvesOf("FEmusic_explore") }
            (releases.await() + explore.await()).distinctBy { it.title }
        }
    }

    /** Moods and genres, for the Search tab's category grid. */
    @Throws(Throwable::class)
    suspend fun categories(): List<BrowseCategory> = call("categories") {
        InnertubeParser.parseMoodAndGenres(browse("FEmusic_moods_and_genres"))
            .flatMap { section -> section.items }
            .map { BrowseCategory(it.title, it.browseId, it.params, it.stripeColor, Artwork.sized(it.thumbnailUrl, 600)) }
            .distinctBy { it.browseId + it.params.orEmpty() }
    }

    @Throws(Throwable::class)
    suspend fun categoryShelves(browseId: String, params: String?): List<Shelf> = call("category") {
        InnertubeParser.parseHome(browse(browseId, params)).map(Shelf::from).filter { it.items.isNotEmpty() }
    }

    // ---------------------------------------------------------------- search

    @Throws(Throwable::class)
    suspend fun search(query: String, scope: SearchScope): SearchResults = call("search") {
        val filter = when (scope) {
            SearchScope.ALL -> SearchFilter.ALL
            SearchScope.SONGS -> SearchFilter.SONGS
            SearchScope.ALBUMS -> SearchFilter.ALBUMS
            SearchScope.ARTISTS -> SearchFilter.ARTISTS
            SearchScope.PLAYLISTS -> SearchFilter.PLAYLISTS
            SearchScope.VIDEOS -> SearchFilter.VIDEOS
        }
        ensureSession()
        val response = read(innerTube.search(YouTubeClient.WEB_REMIX, query = query, params = filter.params, setLogin = false))
        val page = InnertubeParser.parseSearchPage(response, includeVideos = scope == SearchScope.VIDEOS || scope == SearchScope.ALL)
        resultsOf(page.rows, page.continuation)
    }

    @Throws(Throwable::class)
    suspend fun searchSuggestions(input: String): List<String> = call("suggestions") {
        if (input.isBlank()) return@call emptyList()
        ensureSession()
        InnertubeParser.parseSearchSuggestions(read(innerTube.getSearchSuggestions(YouTubeClient.WEB_REMIX, input)))
    }

    private fun resultsOf(rows: List<SearchResult>, continuation: String?): SearchResults {
        var top: MediaItem? = null
        val songs = ArrayList<Track>()
        val videos = ArrayList<Track>()
        val albums = ArrayList<MediaItem>()
        val artists = ArrayList<MediaItem>()
        val playlists = ArrayList<MediaItem>()
        rows.forEach { row ->
            when (row) {
                is SearchResult.TopTrack -> {
                    val track = Track.from(row.song)
                    if (top == null) top = MediaItem.from(track)
                    (if (track.isVideo) videos else songs) += track
                }
                is SearchResult.Track -> Track.from(row.song).let { (if (it.isVideo) videos else songs) += it }
                is SearchResult.Browse -> {
                    val item = MediaItem.from(row.item)
                    when (item.kind) {
                        ItemKind.ALBUM, ItemKind.SINGLE -> albums += item
                        ItemKind.ARTIST -> artists += item
                        ItemKind.PLAYLIST, ItemKind.PODCAST -> playlists += item
                        else -> Unit
                    }
                }
            }
        }
        if (top == null) top = artists.firstOrNull() ?: songs.firstOrNull()?.let(MediaItem::from)
        return SearchResults(top, songs.distinctBy { it.videoId }, albums, artists, playlists, videos.distinctBy { it.videoId }, continuation)
    }

    // ---------------------------------------------------------------- pages

    /**
     * An album (`MPREb…`) or playlist (`VL…`) page. An album's own rows are
     * sometimes a preview; its backing playlist then has the full listing, and
     * is used when it really is longer, as BitChord's `albumPageOf` decides.
     */
    @Throws(Throwable::class)
    suspend fun collection(browseId: String): CollectionPage = call("collection") {
        val response = browse(browseId)
        val header = InnertubeParser.parseBrowseHeader(response)
        val kind = MediaItem.kindOf(browseId, header?.subtitle.orEmpty())
        var listing = listingOf(response)
        if (browseId.startsWith("MPREb")) {
            InnertubeParser.parseAlbumPlaylistId(response)?.let { playlistId ->
                val playlist = runCatching { browse("VL${playlistId.removePrefix("VL")}") }.getOrNull()
                val candidate = playlist?.let(::listingOf)
                if (candidate != null && (candidate.tracks.size >= listing.tracks.size || candidate.continuation != null)) {
                    listing = candidate
                }
            }
        }
        CollectionPage(
            browseId = browseId,
            kind = kind,
            title = header?.title.orEmpty(),
            subtitle = header?.subtitle.orEmpty(),
            artworkUrl = Artwork.sized(header?.thumbnailUrl, 1200),
            about = InnertubeParser.parseDescription(response),
            tracks = listing.tracks,
            continuation = listing.continuation,
        )
    }

    /** More rows of an album or playlist, from [CollectionPage.continuation]. */
    @Throws(Throwable::class)
    suspend fun moreTracks(continuation: String): TrackPage = call("collection:more") {
        listingOf(browseContinuation(continuation))
    }

    private fun listingOf(response: JsonObject): TrackPage {
        InnertubeParser.parsePlaylistShelf(response)?.let { shelf ->
            return TrackPage(shelf.songs.map(Track::from), shelf.continuation)
        }
        return TrackPage(
            tracks = InnertubeParser.collectSongsDeep(response).distinctBy { it.videoId }.map(Track::from),
            continuation = InnertubeParser.continuationToken(response),
        )
    }

    @Throws(Throwable::class)
    suspend fun artist(browseId: String): ArtistDetail = call("artist") {
        val page = InnertubeParser.parseArtistPage(browse(browseId))
        ArtistDetail(
            browseId = browseId,
            name = page.name.orEmpty(),
            artworkUrl = Artwork.sized(page.thumbnailUrl, 1440),
            about = page.description,
            subscriberText = page.subscriberCountText,
            monthlyListeners = page.monthlyListenerCount,
            topSongs = page.songs.map(Track::from),
            shelves = page.sections.map(Shelf::from).filter { it.items.isNotEmpty() },
            radioPlaylistId = page.radio?.playlistId,
            radioParams = page.radio?.params,
            shufflePlaylistId = page.shuffle?.playlistId,
            shuffleParams = page.shuffle?.params,
        )
    }

    /**
     * The queue YouTube Music would play after [videoId] (its automix / radio),
     * or a playlist's own queue when [playlistId] is given.
     */
    @Throws(Throwable::class)
    suspend fun upNext(videoId: String?, playlistId: String?, params: String?): List<Track> = call("next") {
        ensureSession()
        val response = read(
            innerTube.next(
                YouTubeClient.WEB_REMIX,
                videoId = videoId,
                playlistId = playlistId ?: videoId?.let { "RDAMVM$it" },
                params = params,
            ),
        )
        InnertubeParser.parseWatchQueue(response, preferAudio = true).map(Track::from)
    }

    // ---------------------------------------------------------------- playback

    /**
     * A URL AVPlayer can open for [videoId].
     *
     * Asked for AAC in MP4, no SABR (AVPlayer cannot play it) and no HLS
     * (YouTube's HLS for these clients muxes video in, for nothing). A client
     * whose URL only serves bounded byte ranges is skipped while another one
     * can answer, since AVPlayer then needs the app's chunked loader.
     *
     * @param excludedProfiles profile ids whose URL AVPlayer already failed on.
     */
    @Throws(Throwable::class)
    suspend fun resolveStream(videoId: String, excludedProfiles: List<String>): PlayableStream = call("stream") {
        ensureSession()
        val excluded = excludedProfiles.toMutableSet()
        var bounded: ExtractedStream? = null
        repeat(MAX_CLIENT_ATTEMPTS) {
            val stream = extractor.extract(
                videoId = videoId,
                hints = ContentHints().withStreamCapabilities(allowHls = false, allowSabr = false, allowBoundedRange = true),
                excludedClients = excluded,
                audioQuality = AudioQuality.MP4,
                clientPlaybackNonce = generateClientPlaybackNonce(),
            ) ?: return@repeat
            when {
                stream.sabrBootstrap != null -> excluded += stream.profileId
                stream.requireBoundedRange -> {
                    if (bounded == null) bounded = stream
                    excluded += stream.profileId
                }
                else -> return@call playable(stream)
            }
        }
        bounded?.let { return@call playable(it) }
        throw MusicServiceException("No playable audio for this track")
    }

    private fun playable(stream: ExtractedStream) = PlayableStream(
        videoId = stream.videoId,
        url = stream.audioUrl,
        headers = stream.headers,
        mimeType = stream.mimeType,
        bitrateKbps = (stream.bitrate ?: 0) / 1000,
        loudnessDb = stream.loudnessDb,
        expiresAtEpochSeconds = stream.expiresAt?.epochSeconds,
        profileId = stream.profileId,
        clientName = stream.clientName,
        requiresBoundedRange = stream.requireBoundedRange,
        rangeChunkSizeBytes = stream.rangeChunkSizeBytes,
        contentLengthBytes = stream.contentLengthBytes,
    )

    // ---------------------------------------------------------------- plumbing

    private suspend fun browse(browseId: String, params: String? = null): JsonObject {
        ensureSession()
        return read(innerTube.browse(YouTubeClient.WEB_REMIX, browseId = browseId, params = params, setLogin = false))
    }

    private suspend fun browseContinuation(token: String): JsonObject {
        ensureSession()
        return read(innerTube.browse(YouTubeClient.WEB_REMIX, continuation = token, setLogin = false))
    }

    private suspend fun shelvesOf(browseId: String): List<Shelf> =
        InnertubeParser.parseHome(browse(browseId)).map(Shelf::from).filter { it.items.isNotEmpty() }

    private suspend fun read(response: HttpResponse): JsonObject {
        val text = response.bodyAsText()
        if (!response.status.isSuccess()) {
            throw MusicServiceException("YouTube Music answered ${response.status.value}")
        }
        return json.parseToJsonElement(text).jsonObject
    }

    /** Turns every failure into a [MusicServiceException], which Swift receives as an `Error`. */
    private suspend fun <T> call(what: String, block: suspend () -> T): T =
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: MusicServiceException) {
            KitLog.w(TAG, "$what: ${e.message}")
            throw e
        } catch (e: Throwable) {
            KitLog.w(TAG, "$what failed: ${e::class.simpleName}: ${e.message}")
            throw MusicServiceException(e.message ?: "Something went wrong ($what)", e)
        }

    private companion object {
        const val TAG = "MusicService"
        const val VISITOR_DATA_KEY = "yt.visitorData"
        const val MAX_CLIENT_ATTEMPTS = 4

        // The remote cipher hints BitChord's InnerTubeXResolver points InnerTubeX at.
        const val PLAYER_CONFIG_URL =
            "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json"
    }
}
