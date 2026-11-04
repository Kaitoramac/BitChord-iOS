package com.music.bitchord.kit.potoken

import com.metrolist.innertubex.extraction.PoTokenResult
import com.metrolist.innertubex.extraction.TokenProvider
import com.metrolist.innertubex.extraction.TokenProviderCapabilities
import com.metrolist.innertubex.extraction.potoken.parseIntegrityTokenData
import com.metrolist.innertubex.extraction.potoken.requireTrustedAttestationInterpreterUrl
import com.metrolist.innertubex.extraction.potoken.stringToU8
import com.metrolist.innertubex.extraction.potoken.u8ToBase64
import com.metrolist.innertubex.extraction.strategy.PoTokenProviderKind
import com.music.bitchord.kit.JavaScriptHost
import com.music.bitchord.kit.KitLog
import com.music.bitchord.kit.PageLoadCallback
import com.music.bitchord.kit.ScriptCallback
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.TextContent
import io.ktor.http.isSuccess
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonPrimitive

/**
 * PO tokens minted by YouTube's own BotGuard, run inside a WKWebView, as
 * BitChord does on Android (`PoTokenWebView`) and desktop (JavaFX).
 *
 * Two tokens per request, exactly as BitChord's `PoTokenGenerator` pairs them:
 * one bound to the session's visitor data (minted once per session) and one
 * bound to the videoId (minted per track).
 *
 * Any failure returns null rather than throwing: InnerTubeX then falls back to
 * the clients that need no token, which is the normal path for most tracks.
 */
internal class BotGuardTokenProvider(
    private val host: JavaScriptHost,
    private val http: HttpClient,
) : TokenProvider {

    override val capabilities = TokenProviderCapabilities(
        providers = setOf(PoTokenProviderKind.WEB_BOTGUARD),
        usesWebView = true,
    )

    private val lock = Mutex()
    private var minter: Minter? = null
    private var sessionId: String? = null
    private var sessionToken: String? = null

    override suspend fun getPoToken(videoId: String, visitorData: String, cookie: String?): PoTokenResult? =
        try {
            withTimeout(TIMEOUT) { tokensFor(videoId, visitorData, retry = true) }
        } catch (e: CancellationException) {
            // withTimeout's own cancellation is a timeout, not the caller cancelling.
            if (e is kotlinx.coroutines.TimeoutCancellationException) {
                KitLog.w(TAG, "PO token timed out, continuing without one")
                lock.withLock { dropMinter() }
                null
            } else {
                throw e
            }
        } catch (e: Exception) {
            KitLog.w(TAG, "PO token failed (${e::class.simpleName}): ${e.message}")
            lock.withLock { dropMinter() }
            null
        }

    override suspend fun invalidateAttestation() {
        lock.withLock { dropMinter() }
    }

    override suspend fun close() {
        lock.withLock { dropMinter() }
    }

    private suspend fun tokensFor(videoId: String, visitorData: String, retry: Boolean): PoTokenResult {
        val (current, sessionPot) = lock.withLock {
            val existing = minter
            if (existing == null || existing.isExpired || sessionId != visitorData || sessionToken == null) {
                dropMinter()
                val created = createMinter()
                minter = created
                sessionToken = created.mint(visitorData)
                sessionId = visitorData
            }
            minter!! to sessionToken!!
        }
        val videoPot = try {
            current.mint(videoId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!retry) throw e
            KitLog.w(TAG, "minting for the track failed, rebuilding the BotGuard page")
            lock.withLock { dropMinter() }
            return tokensFor(videoId, visitorData, retry = false)
        }
        return PoTokenResult(
            playerRequestToken = sessionPot,
            streamingDataToken = videoPot,
            visitorData = visitorData,
        )
    }

    private fun dropMinter() {
        if (minter != null) host.reset()
        minter = null
        sessionId = null
        sessionToken = null
    }

    private suspend fun createMinter(): Minter {
        host.load(PO_TOKEN_HTML, "https://www.youtube.com/")

        var challenge = parseChallengeData(botGuardRequest(CREATE_URL, "[ \"$REQUEST_KEY\" ]"))
        if (challenge.interpreterJavascript == null) {
            val url = challenge.interpreterUrl ?: throw IllegalStateException("BotGuard challenge has no interpreter")
            challenge = challenge.withInterpreter(fetchInterpreter(url))
        }

        val botguardResponse = host.run(
            """
            const result = await runBotGuard(${challenge.toJavaScript()});
            window.__bitchordWebPoSignalOutput = result.webPoSignalOutput;
            return String(result.botguardResponse);
            """.trimIndent(),
        )

        val integrity = parseIntegrityTokenData(
            botGuardRequest(GENERATE_IT_URL, "[ \"$REQUEST_KEY\", ${JsonPrimitive(botguardResponse)} ]"),
        )
        host.run(
            """
            await createPoTokenMinter(window.__bitchordWebPoSignalOutput, ${integrity.tokenJavaScript});
            return "ready";
            """.trimIndent(),
        )
        // Rebuild a little before YouTube's own expiry so a token is never minted from a stale integrity token.
        val lifetime = (integrity.lifetimeSeconds - 10 * 60).coerceAtLeast(60).seconds
        KitLog.d(TAG, "BotGuard minter ready, valid for $lifetime")
        return Minter(TimeSource.Monotonic.markNow() + lifetime)
    }

    private inner class Minter(private val expiresAt: TimeSource.Monotonic.ValueTimeMark) {
        val isExpired: Boolean get() = expiresAt.hasPassedNow()

        suspend fun mint(identifier: String): String {
            val u8 = host.run(
                """
                const token = await obtainPoToken(${stringToU8(identifier)});
                return Array.from(token).join(",");
                """.trimIndent(),
            )
            return u8ToBase64(u8)
        }
    }

    private suspend fun botGuardRequest(url: String, body: String): String {
        val response = http.post(url) {
            header("x-goog-api-key", GOOGLE_API_KEY)
            header("x-user-agent", "grpc-web-javascript/0.1")
            header("User-Agent", SAFARI_USER_AGENT)
            // An explicit OutgoingContent: Ktor sets Content-Type from it, and ContentNegotiation leaves it alone.
            setBody(TextContent(body, JSON_PROTOBUF))
        }
        val text = response.bodyAsText()
        check(response.status.isSuccess() && text.isNotBlank()) { "BotGuard request failed (${response.status.value})" }
        return text
    }

    private suspend fun fetchInterpreter(url: String): String {
        val trusted = requireTrustedAttestationInterpreterUrl(url)
        val response = http.get(trusted) { header("User-Agent", SAFARI_USER_AGENT) }
        check(response.status.isSuccess()) { "BotGuard interpreter download failed (${response.status.value})" }
        return response.bodyAsText()
    }

    private companion object {
        const val TAG = "PoToken"
        const val CREATE_URL = "https://www.youtube.com/api/jnn/v1/Create"
        const val GENERATE_IT_URL = "https://www.youtube.com/api/jnn/v1/GenerateIT"
        // The web client's public BotGuard key and API key, as BitChord's PoTokenWebView uses them.
        const val REQUEST_KEY = "O43z0dpjhgX20SCx4KAo"
        const val GOOGLE_API_KEY = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
        const val SAFARI_USER_AGENT =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        val TIMEOUT = 15.seconds
        val JSON_PROTOBUF = ContentType("application", "json+protobuf")
    }
}

private suspend fun JavaScriptHost.load(html: String, baseUrl: String): Unit =
    suspendCancellableCoroutine { continuation ->
        loadPage(html, baseUrl, object : PageLoadCallback {
            override fun onPageLoaded(error: String?) {
                if (!continuation.isActive) return
                if (error == null) continuation.resume(Unit)
                else continuation.resumeWithException(IllegalStateException("BotGuard page failed to load: $error"))
            }
        })
    }

private suspend fun JavaScriptHost.run(body: String): String =
    suspendCancellableCoroutine { continuation ->
        evaluate(body, object : ScriptCallback {
            override fun onScriptResult(result: String?, error: String?) {
                if (!continuation.isActive) return
                when {
                    error != null -> continuation.resumeWithException(IllegalStateException("BotGuard script failed: $error"))
                    result == null -> continuation.resumeWithException(IllegalStateException("BotGuard script returned nothing"))
                    else -> continuation.resume(result)
                }
            }
        })
    }
