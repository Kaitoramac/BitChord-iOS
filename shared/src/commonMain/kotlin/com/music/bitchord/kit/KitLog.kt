package com.music.bitchord.kit

import kotlin.concurrent.Volatile

/** Routes the shared code's diagnostics to whatever logger the app installed. */
internal object KitLog {
    @Volatile
    var sink: KitLogger? = null

    @Volatile
    var debug: Boolean = false

    fun d(tag: String, message: String) {
        if (debug) sink?.log("debug", tag, message)
    }

    fun i(tag: String, message: String) {
        sink?.log("info", tag, message)
    }

    fun w(tag: String, message: String) {
        sink?.log("warning", tag, message)
    }

    fun e(tag: String, message: String) {
        sink?.log("error", tag, message)
    }
}
