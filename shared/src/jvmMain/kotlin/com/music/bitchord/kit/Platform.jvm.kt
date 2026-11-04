package com.music.bitchord.kit

import java.text.Normalizer
import java.util.concurrent.locks.ReentrantLock

actual class KitLock actual constructor() {
    private val lock = ReentrantLock()

    actual fun <T> withLock(block: () -> T): T {
        lock.lock()
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }
}

actual fun decomposeCanonical(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFD)
