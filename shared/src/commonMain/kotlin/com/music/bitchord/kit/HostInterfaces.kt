package com.music.bitchord.kit

/*
 * What the iOS app provides to the shared code. Kotlin interfaces become Swift
 * protocols, and plain callbacks keep the Swift side free of Kotlin coroutines.
 */

/** Small persistent storage, backed by UserDefaults on iOS. */
interface KeyValueStore {
    fun getString(key: String): String?

    /** A null [value] removes the key. */
    fun putString(key: String, value: String?)
}

/**
 * A browser page that can run YouTube's BotGuard, a WKWebView on iOS.
 *
 * Both calls may be made from any thread; the implementation hops to whatever
 * thread its web view needs and answers its callback exactly once.
 *
 * Callbacks are interfaces rather than Kotlin lambdas so their Swift signatures
 * are plain methods (a Kotlin `(String?) -> Unit` would reach Swift returning `KotlinUnit`).
 */
interface JavaScriptHost {
    /** Loads [html] as if it were served from [baseUrl]. */
    fun loadPage(html: String, baseUrl: String, callback: PageLoadCallback)

    /**
     * Runs [body] as the body of an async function in the loaded page (so `await`
     * and `return` work) and answers with the returned value as a string, or with
     * an error message. WKWebView's `callAsyncJavaScript` does exactly this.
     */
    fun evaluate(body: String, callback: ScriptCallback)

    /** Throws the page away; the next [loadPage] starts fresh. */
    fun reset()
}

interface PageLoadCallback {
    /** [error] is null when the page loaded. */
    fun onPageLoaded(error: String?)
}

interface ScriptCallback {
    fun onScriptResult(result: String?, error: String?)
}

/** Optional sink for the shared code's diagnostics. */
interface KitLogger {
    fun log(level: String, tag: String, message: String)
}
