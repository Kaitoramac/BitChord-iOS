package com.music.bitchord.kit

import kotlinx.cinterop.BetaInteropApi
import platform.Foundation.NSRecursiveLock
import platform.Foundation.NSString
import platform.Foundation.create
import platform.Foundation.decomposedStringWithCanonicalMapping

actual class KitLock actual constructor() {
    private val lock = NSRecursiveLock()

    actual fun <T> withLock(block: () -> T): T {
        lock.lock()
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }
}

@OptIn(BetaInteropApi::class)
actual fun decomposeCanonical(value: String): String =
    NSString.create(string = value).decomposedStringWithCanonicalMapping
