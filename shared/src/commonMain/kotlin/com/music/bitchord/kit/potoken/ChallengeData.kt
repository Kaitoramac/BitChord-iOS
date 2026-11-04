// Ported from BitChord's JavaScriptUtil.parseChallengeData (GPL-3.0): okio base64 replaced by kotlin.io.encoding.
package com.music.bitchord.kit.potoken

import kotlin.io.encoding.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/** What `jnn/v1/Create` answered, made ready for the page's `runBotGuard`. */
internal class BotGuardChallenge(
    /** The JSON object literal `runBotGuard` takes. */
    val json: JsonObject,
) {
    val interpreterJavascript: String?
        get() = wrapped("privateDoNotAccessOrElseSafeScriptWrappedValue")

    val interpreterUrl: String?
        get() = wrapped("privateDoNotAccessOrElseTrustedResourceUrlWrappedValue")

    private fun wrapped(key: String): String? =
        (json["interpreterJavascript"] as? JsonObject)?.get(key)
            ?.takeIf { it !is JsonNull }
            ?.jsonPrimitive?.content
            ?.takeIf { it.isNotBlank() }

    /** A copy carrying [script] as the interpreter, for challenges that only named its URL. */
    fun withInterpreter(script: String): BotGuardChallenge {
        val interpreter = JsonObject(
            mapOf(
                "privateDoNotAccessOrElseSafeScriptWrappedValue" to JsonPrimitive(script),
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue" to (interpreterUrl?.let(::JsonPrimitive) ?: JsonNull),
            ),
        )
        return BotGuardChallenge(JsonObject(json + ("interpreterJavascript" to interpreter)))
    }

    fun toJavaScript(): String = json.toString()
}

internal fun parseChallengeData(rawChallengeData: String): BotGuardChallenge {
    val scrambled = Json.parseToJsonElement(rawChallengeData).jsonArray

    val challengeData = if (scrambled.size > 1 && scrambled[1].jsonPrimitive.isString) {
        Json.parseToJsonElement(descramble(scrambled[1].jsonPrimitive.content)).jsonArray
    } else {
        scrambled[0].jsonArray
    }

    fun firstString(element: JsonElement): JsonElement =
        element.takeIf { it !is JsonNull }
            ?.jsonArray
            ?.firstOrNull { it is JsonPrimitive && it.isString }
            ?: JsonNull

    return BotGuardChallenge(
        JsonObject(
            mapOf(
                "messageId" to JsonPrimitive(challengeData[0].jsonPrimitive.content),
                "interpreterJavascript" to JsonObject(
                    mapOf(
                        "privateDoNotAccessOrElseSafeScriptWrappedValue" to firstString(challengeData[1]),
                        "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue" to firstString(challengeData[2]),
                    ),
                ),
                "interpreterHash" to JsonPrimitive(challengeData[3].jsonPrimitive.content),
                "program" to JsonPrimitive(challengeData[4].jsonPrimitive.content),
                "globalName" to JsonPrimitive(challengeData[5].jsonPrimitive.content),
                "clientExperimentsStateBlob" to JsonPrimitive(challengeData[7].jsonPrimitive.content),
            ),
        ),
    )
}

/** The scrambled challenge is base64 with 97 subtracted from every byte. */
private fun descramble(scrambledChallenge: String): String =
    youtubeBase64(scrambledChallenge)
        .map { (it + 97).toByte() }
        .toByteArray()
        .decodeToString()

/** YouTube's URL-safe base64, with `.` standing in for padding. */
private fun youtubeBase64(value: String): ByteArray {
    val standard = value.replace('-', '+').replace('_', '/').replace('.', '=')
    return Base64.Default
        .withPadding(Base64.PaddingOption.PRESENT_OPTIONAL)
        .decode(standard)
}
