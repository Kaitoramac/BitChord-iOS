plugins {
    // Same compiler as InnerTubeX v0.11.0: Kotlin/Native klibs are not read by an older compiler.
    kotlin("multiplatform") version "2.4.21" apply false
    kotlin("plugin.serialization") version "2.4.21" apply false
}
