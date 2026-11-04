package com.music.bitchord.kit

import com.music.bitchord.data.model.BrowseItem
import com.music.bitchord.data.model.BrowseType
import com.music.bitchord.data.model.HomeShelf
import com.music.bitchord.data.model.ShelfItem
import com.music.bitchord.data.model.ShelfLayout
import com.music.bitchord.data.model.Song

/*
 * The types Swift sees. They are deliberately small and flat: the BitChord models
 * behind them keep evolving upstream, and the iOS app should not have to follow
 * every field. Everything here is immutable and safe to hand across threads.
 */

/** A playable track. */
class Track(
    val videoId: String,
    val title: String,
    val artist: String,
    val artistId: String?,
    val album: String?,
    val albumId: String?,
    /** Largest artwork YouTube serves for the row, see [Artwork.sized]. */
    val artworkUrl: String?,
    val durationText: String?,
    val isVideo: Boolean,
) {
    internal companion object {
        fun from(song: Song) = Track(
            videoId = song.videoId,
            title = song.title,
            artist = song.artist,
            artistId = song.artistId,
            album = song.albumName,
            albumId = song.albumId,
            artworkUrl = Artwork.sized(song.thumbnailUrl, 1200),
            durationText = song.durationText,
            isVideo = song.isVideo,
        )
    }
}

enum class ItemKind { SONG, VIDEO, ALBUM, SINGLE, PLAYLIST, ARTIST, PODCAST, OTHER }

/** A card in a shelf or a search row: something that opens a page or plays. */
class MediaItem(
    val kind: ItemKind,
    val title: String,
    val subtitle: String,
    val artworkUrl: String?,
    /** Set for songs and videos: tap plays it. */
    val videoId: String?,
    /** Set for albums, playlists and artists: tap opens it. */
    val browseId: String?,
) {
    val id: String get() = videoId ?: browseId ?: "$kind:$title:$subtitle"

    internal companion object {
        fun from(item: ShelfItem): MediaItem {
            val kind = when {
                item.videoId != null -> if (item.isVideo) ItemKind.VIDEO else ItemKind.SONG
                else -> kindOf(item.browseId, item.subtitle)
            }
            return MediaItem(kind, item.title, item.subtitle, Artwork.sized(item.thumbnailUrl, 800), item.videoId, item.browseId)
        }

        fun from(item: BrowseItem): MediaItem {
            val kind = when (item.type) {
                BrowseType.ALBUM -> if (item.subtitle.startsWith("Single")) ItemKind.SINGLE else ItemKind.ALBUM
                BrowseType.ARTIST -> ItemKind.ARTIST
                BrowseType.PLAYLIST -> ItemKind.PLAYLIST
                BrowseType.OTHER -> kindOf(item.browseId, item.subtitle)
            }
            return MediaItem(kind, item.title, item.subtitle, Artwork.sized(item.thumbnailUrl, 800), null, item.browseId)
        }

        fun from(track: Track) = MediaItem(
            kind = if (track.isVideo) ItemKind.VIDEO else ItemKind.SONG,
            title = track.title,
            subtitle = track.artist,
            artworkUrl = track.artworkUrl,
            videoId = track.videoId,
            browseId = null,
        )

        /** YouTube Music browse ids carry their page type in their prefix. */
        fun kindOf(browseId: String?, subtitle: String): ItemKind = when {
            browseId == null -> ItemKind.OTHER
            browseId.startsWith("MPREb") ->
                if (subtitle.startsWith("Single") || subtitle.startsWith("EP")) ItemKind.SINGLE else ItemKind.ALBUM
            browseId.startsWith("UC") || browseId.startsWith("FEmusic_library_privately_owned_artist") -> ItemKind.ARTIST
            browseId.startsWith("MPSP") -> ItemKind.PODCAST
            browseId.startsWith("VL") || browseId.startsWith("PL") || browseId.startsWith("RD") ||
                browseId.startsWith("OLAK") -> ItemKind.PLAYLIST
            else -> ItemKind.OTHER
        }
    }
}

enum class ShelfStyle {
    /** Square artwork cards in a horizontal row. */
    CARDS,
    /** Track rows, paged horizontally in columns of four (Apple Music's "Top Songs"). */
    LIST,
    /** 16:9 cards. */
    VIDEO,
}

class Shelf(
    val title: String,
    val subtitle: String,
    val items: List<MediaItem>,
    val style: ShelfStyle,
) {
    internal companion object {
        fun from(shelf: HomeShelf) = Shelf(
            title = shelf.title,
            subtitle = shelf.subtitle,
            items = shelf.items.map(MediaItem::from),
            style = when (shelf.layout) {
                ShelfLayout.CARDS -> ShelfStyle.CARDS
                ShelfLayout.LIST -> ShelfStyle.LIST
                ShelfLayout.VIDEO -> ShelfStyle.VIDEO
            },
        )
    }
}

class HomePage(val shelves: List<Shelf>, val continuation: String?)

class SearchResults(
    /** The first row, when YouTube marked one as the top result. */
    val top: MediaItem?,
    val songs: List<Track>,
    val albums: List<MediaItem>,
    val artists: List<MediaItem>,
    val playlists: List<MediaItem>,
    val videos: List<Track>,
    val continuation: String?,
) {
    val isEmpty: Boolean
        get() = top == null && songs.isEmpty() && albums.isEmpty() && artists.isEmpty() && playlists.isEmpty() && videos.isEmpty()
}

/** An album or a playlist page. */
class CollectionPage(
    val browseId: String,
    val kind: ItemKind,
    val title: String,
    /** "Album · Artist · 2024", or a playlist's byline. */
    val subtitle: String,
    val artworkUrl: String?,
    /** The page's blurb (named `about`: `description` clashes with NSObject in Swift). */
    val about: String?,
    val tracks: List<Track>,
    val continuation: String?,
)

class ArtistDetail(
    val browseId: String,
    val name: String,
    val artworkUrl: String?,
    val about: String?,
    val subscriberText: String?,
    val monthlyListeners: String?,
    val topSongs: List<Track>,
    val shelves: List<Shelf>,
    /** Playlist id of the artist's Mix, when the page offers one. */
    val radioPlaylistId: String?,
    val radioParams: String?,
    val shufflePlaylistId: String?,
    val shuffleParams: String?,
)

/** What the player needs to open a track. */
class PlayableStream(
    val videoId: String,
    val url: String,
    /** Headers every request for [url] must carry (User-Agent, Origin...). */
    val headers: Map<String, String>,
    val mimeType: String?,
    val bitrateKbps: Int,
    /** YouTube's loudness normalisation value, in dB relative to its target. */
    val loudnessDb: Double?,
    /** Epoch seconds after which [url] stops working, when YouTube says. */
    val expiresAtEpochSeconds: Long?,
    /** InnerTubeX's id for the client that minted [url]; pass it back to skip that client. */
    val profileId: String,
    val clientName: String,
    /**
     * The server refuses open-ended `Range: bytes=N-` requests for [url]: it has
     * to be read in chunks of at most [rangeChunkSizeBytes], which the app's
     * resource loader does. False for most streams.
     */
    val requiresBoundedRange: Boolean,
    val rangeChunkSizeBytes: Long,
    val contentLengthBytes: Long?,
)

object Artwork {
    private val SIZE = Regex("""=w\d+-h\d+""")
    private val SIZE_ALT = Regex("""=s\d+""")

    /**
     * YouTube serves `lh3.googleusercontent.com`/`yt3.ggpht.com` art at any size the URL
     * asks for; rows ask for 60-226 px. Apple-Music-sized art needs far more.
     * `i.ytimg.com` video thumbnails are fixed files and pass through unchanged.
     */
    fun sized(url: String?, pixels: Int): String? {
        url ?: return null
        return when {
            SIZE.containsMatchIn(url) -> SIZE.replace(url, "=w$pixels-h$pixels")
            SIZE_ALT.containsMatchIn(url) -> SIZE_ALT.replace(url, "=s$pixels")
            else -> url
        }
    }
}
