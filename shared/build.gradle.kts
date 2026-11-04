plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
}

val ktor = "3.6.0"

kotlin {
    // JVM target: lets the shared code be compiled and smoke-tested on any machine, Mac or not.
    jvm()

    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "BitChordKit"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            api("com.github.MetrolistGroup.innertubex:innertubex:v0.11.0")
            implementation("io.ktor:ktor-client-core:$ktor")
            implementation("io.ktor:ktor-client-content-negotiation:$ktor")
            implementation("io.ktor:ktor-serialization-kotlinx-json:$ktor")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
        }
        jvmMain.dependencies {
            implementation("io.ktor:ktor-client-okhttp:$ktor")
        }
        iosMain.dependencies {
            implementation("io.ktor:ktor-client-darwin:$ktor")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
        }
    }
}
