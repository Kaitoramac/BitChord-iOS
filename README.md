# BitChord for iOS

An iOS client for [BitChord](https://github.com/kushagrasinghx/BitChord): YouTube Music, with an interface modelled on Apple Music. SwiftUI for the app, Kotlin Multiplatform for everything that talks to YouTube.

> Status: first milestone, not yet built on a Mac. The Kotlin module and the Swift app were written against the real InnerTubeX v0.11.0 and BitChord sources, but the first `xcodebuild` may surface a few compile errors to fix. The pure Kotlin logic (URL decoding, artwork sizing, browse id classification) was compiled and run with `kotlinc`.

## What works in this milestone

- **Home, New, Radio, Library, Search** tabs, with the mini player in the tab bar accessory (Liquid Glass on iOS 26, a floating bar on iOS 18).
- **Album / playlist pages**: big artwork, accent-coloured artist line, Play / Shuffle capsules, numbered tracks, paging through long playlists.
- **Artist pages**: full-bleed stretchy photo, play button (artist Shuffle or Mix), Top Songs in paged columns, discography shelves.
- **Search**: suggestions while typing, recent searches, browse categories, scoped results (Top / Songs / Albums / Artists / Playlists), top result card.
- **Now Playing**: animated mesh background from the artwork's colours, artwork that shrinks on pause, thick scrubber, system volume, AirPlay, **time-synced lyrics** (LRCLIB) and the **queue** (reorder, remove, shuffle, repeat, autoplay ∞).
- **Playback**: gapless via `AVQueuePlayer`, background audio, lock screen and Control Center, Sound Check (YouTube loudness normalisation), interruption handling, queue restored on relaunch.
- **Library on device**: add albums, playlists, artists and songs; recently played and recently added.

## Architecture

```
iosApp (SwiftUI)                        shared (Kotlin Multiplatform → BitChordKit.framework)
────────────────────────────────        ──────────────────────────────────────────────────
Views ── AppModel ── Player ──┐         MusicService  (facade, `async throws` in Swift)
                              │           ├─ InnerTube (InnerTubeX)    browse / search / next
             CatalogService ──┼────────▶  ├─ InnertubeParser (BitChord) JSON → pages
                              │           ├─ InnerTubeExtractor        stream URLs, cipher (QuackJS)
   UserDefaultsStore ─────────┤           └─ BotGuardTokenProvider     PO tokens
   WebViewJavaScriptHost ─────┘                └─ runs BitChord's BotGuard page in a WKWebView
```

- **Catalogue** requests go through [InnerTubeX](https://github.com/MetrolistGroup/innertubex) as the `WEB_REMIX` client and are read by BitChord's own `InnertubeParser`, ported to common Kotlin (only `Locale`, `URLDecoder` and `String.format` had to go). Pages therefore come out exactly as on BitChord for Android.
- **Streams** come from InnerTubeX's extractor, asked for **AAC in MP4**, the format AVPlayer plays natively (Android prefers Opus/WebM, which iOS cannot play). SABR and HLS are disabled; a client whose URL only accepts bounded ranges is skipped while another can answer, and otherwise served through `ChunkedResourceLoader`.
- If AVPlayer refuses a URL, the track is resolved again with that YouTube client excluded, as BitChord does.
- **PO tokens** follow BitChord's `PoTokenGenerator`: the same BotGuard page, run in a hidden `WKWebView` through `callAsyncJavaScript`. Any failure there just means InnerTubeX falls back to the clients that need no token.
- Swift never touches Kotlin types outside `CatalogService`: the UI uses its own `Song`, `Card`, `ShelfModel`… value types.

## Build

Requirements: a Mac with **Xcode 26** (the app targets iOS 18+, and uses iOS 26 APIs when available), **JDK 21**, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
# 1. Optional: check the Kotlin side on its own (JVM target, any OS)
./gradlew :shared:jvmTest                     # offline tests
BITCHORD_LIVE=1 ./gradlew :shared:jvmTest     # hits YouTube Music: home, search, stream URL, album

# 2. Generate the Xcode project
cd iosApp && xcodegen

# 3. Open BitChord.xcodeproj, pick your Team under Signing & Capabilities, run on a device or simulator.
#    The "Build BitChordKit (Kotlin)" phase compiles the framework through Gradle on each build.
```

Diagnostics go to the unified log: Console.app, subsystem `com.music.bitchord` (turn on Settings → Verbose Logging for InnerTubeX's client selection and the PO token flow).

## Phone-only workflow

Develop with Claude Code, build on GitHub Actions, install with SideStore, all from the phone.

```
Claude Code (phone) ── commit / PR ──▶ GitHub ── push to main ──▶ Actions (macOS)
                                                                      │
SideStore (phone) ◀── refresh source ◀── release build-N: BitChord.ipa + source.json
```

1. **One-time setup on a PC**: install SideStore on the iPhone (it needs a pairing file created once from a computer; see the SideStore docs).
2. **Add the source in SideStore**: Sources → + → `https://github.com/Kaitoramac/BitChord-iOS/releases/latest/download/source.json`, then install BitChord from it. SideStore signs it on the phone with your Apple ID (a dedicated one is best).
3. **Each change**: ask Claude Code (claude.ai/code, repository connected) for the change. It works on a branch, opens a PR and checks CI; merge when green. The `main` build publishes `build-N`.
4. **Update**: in SideStore, refresh the source and tap Update. Refresh apps every 7 days (free Apple ID).

Every build has a higher build number (`0.1.<run>`), so SideStore always sees it as an update.

## Installing on an iPhone

Not on the App Store: a third-party YouTube client breaks YouTube's terms, and the code is GPL-3.0.

- **Xcode + free Apple ID**: works, but the app expires after 7 days.
- **Paid Apple Developer account**: a year per signature.
- **EU (DMA)**: distribute the `.ipa` through AltStore PAL, or sideload with SideStore / AltStore.

## Roadmap

- [x] KMP module on iOS: InnerTubeX extraction, BitChord parser, BotGuard PO tokens
- [x] Apple Music-style app: tabs, pages, search, Now Playing, lyrics, queue, lock screen
- [ ] First Mac build and fixes; test the PO token flow on device
- [ ] Sign in with Google (cookies → `InnerTube.cookie`) and sync the YouTube Music library
- [ ] Downloads (`AVAssetDownloadURLSession` / file cache) and offline mode
- [ ] Word-synced lyrics from BitChord's other providers (port `data/lyrics` to common Kotlin)
- [ ] Listen Together (BitChord's Go WebSocket server, protocol in `backend/README.md`)
- [ ] CarPlay, widgets, Live Activity
- [ ] Upstream: propose the iOS targets of `shared/` to BitChord as a pull request

## Credits and licence

GPL-3.0, like the projects it builds on:

- [BitChord](https://github.com/kushagrasinghx/BitChord) by kushagrasinghx and contributors: `InnertubeParser`, the models, the BotGuard page and the PO token flow.
- [InnerTubeX](https://github.com/MetrolistGroup/innertubex) and QuackJS by MetrolistGroup: InnerTube client, stream extraction, cipher.
- [LRCLIB](https://lrclib.net) for lyrics.

Not affiliated with YouTube, Google or Apple. The app's name, icon and code are its own; only the interface conventions follow Apple Music.
