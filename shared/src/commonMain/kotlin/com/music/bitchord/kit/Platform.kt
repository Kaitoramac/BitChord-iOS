package com.music.bitchord.kit

/** A mutual-exclusion lock for plain (non-suspending) code shared across threads. */
expect class KitLock() {
    fun <T> withLock(block: () -> T): T
}

/** Unicode canonical decomposition (NFD): `é` becomes `e` followed by U+0301. */
expect fun decomposeCanonical(value: String): String
