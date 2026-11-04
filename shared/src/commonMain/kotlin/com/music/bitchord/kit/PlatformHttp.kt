package com.music.bitchord.kit

import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig

/** The platform's HTTP engine: URLSession (Darwin) on iOS, OkHttp on the JVM. */
internal expect fun platformHttpClient(configure: HttpClientConfig<*>.() -> Unit): HttpClient
