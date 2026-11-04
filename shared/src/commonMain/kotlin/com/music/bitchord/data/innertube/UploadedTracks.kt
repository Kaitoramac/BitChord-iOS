// Ported from BitChord (GPL-3.0): ConcurrentHashMap replaced by a locked set for Kotlin/Native.
package com.music.bitchord.data.innertube

import com.music.bitchord.kit.KitLock

/** Video ids known to be the signed-in user's own uploads, which need an upload-hinted request. */
object UploadedTracks {

    private const val MAX_REMEMBERED = 20_000

    private val lock = KitLock()
    private val ids = HashSet<String>()

    fun mark(videoId: String) {
        if (videoId.isBlank()) return
        lock.withLock {
            if (ids.size >= MAX_REMEMBERED) ids.clear()
            ids.add(videoId)
        }
    }

    fun contains(videoId: String): Boolean = lock.withLock { videoId in ids }

    /** Forgets everything — an account switch is a different private library. */
    fun clear() {
        lock.withLock { ids.clear() }
    }
}
