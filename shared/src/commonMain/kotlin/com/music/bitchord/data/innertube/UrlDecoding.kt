package com.music.bitchord.data.innertube

/**
 * `application/x-www-form-urlencoded` decoding, as `java.net.URLDecoder.decode(s, "UTF-8")`
 * did in the JVM parser: `+` is a space and `%XX` sequences are UTF-8 bytes.
 * A malformed escape is kept as written rather than throwing.
 */
internal fun decodeUrlComponent(value: String): String {
    if ('%' !in value && '+' !in value) return value
    val out = StringBuilder(value.length)
    val bytes = ArrayList<Byte>()

    fun flushBytes() {
        if (bytes.isNotEmpty()) {
            out.append(bytes.toByteArray().decodeToString())
            bytes.clear()
        }
    }

    var i = 0
    while (i < value.length) {
        val c = value[i]
        when {
            c == '%' && i + 2 <= value.lastIndex -> {
                val byte = value.substring(i + 1, i + 3).toIntOrNull(16)
                if (byte == null) {
                    flushBytes()
                    out.append(c)
                    i++
                } else {
                    bytes += byte.toByte()
                    i += 3
                }
            }
            c == '+' -> {
                flushBytes()
                out.append(' ')
                i++
            }
            else -> {
                flushBytes()
                out.append(c)
                i++
            }
        }
    }
    flushBytes()
    return out.toString()
}
