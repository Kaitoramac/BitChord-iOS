# BitChord iOS: notes for Claude

iOS client for BitChord (YouTube Music), Apple Music-style UI. GPL-3.0.

- `shared/`: Kotlin Multiplatform module exported to Swift as `BitChordKit.framework`. InnerTubeX (YouTube API, stream extraction, cipher) plus BitChord's `InnertubeParser`, ported to common Kotlin. Facade: `kit/MusicService.kt`.
- `iosApp/`: SwiftUI app. `project.yml` is the XcodeGen spec; the `.xcodeproj` is generated in CI and not committed.
- `.github/workflows/ios.yml`: the only place iOS code is compiled.

## There is no Mac

The owner has no macOS machine and often works from his phone. Never suggest steps that need Xcode locally.

- **Kotlin common code** can be checked on Linux: `./gradlew :shared:jvmTest`, if Maven Central and JitPack are reachable from the session. JVM success does **not** prove the iOS build: Kotlin/Native lacks the JVM's `java.*` APIs.
- **Swift, and Kotlin/Native for iOS**, are compiled only by GitHub Actions (`macos-26` runner, about 5 minutes once caches are warm).

## Development loop

1. Work on a branch, commit, push, open a PR. CI builds the PR (IPA as an artifact, no release).
2. Check CI: `gh pr checks --watch` or `gh run watch <id> --exit-status`.
3. If it fails, read the errors: `gh run view <id> --log-failed | grep -E "error:|e: file:|Undefined symbol" | sort -u`. Fix all of them in one commit when possible, since each round trip costs a macOS build.
4. When it is green, merge to `main`. The main build publishes a release `build-N` with `BitChord.ipa` and `source.json`. SideStore on the phone updates from `https://github.com/<owner>/BitChord-iOS/releases/latest/download/source.json`.

If `gh` cannot reach GitHub from the session, say so and give the owner the exact commands to run.

## Pitfalls already hit (do not reintroduce)

Kotlin in `commonMain` must compile for Kotlin/Native:
- No `java.*` / `javax.*`, `Locale`, `String.format`, `ConcurrentHashMap`, `Normalizer`, `synchronized`, `@Synchronized`.
- No `java.util.Map` defaults on Kotlin maps: `putIfAbsent`, `computeIfAbsent`, `merge`, `getOrDefault`, `removeIf`. Use `getOrPut`, `getOrElse`, plain reads and writes.
- Platform needs go through `expect`/`actual` in `kit/Platform.kt`: `KitLock` (locking), `decomposeCanonical` (NFD).
- When copying more files from upstream BitChord, check what they import first. `InnertubeParser` needed `ArtistCredits.kt` and `UploadedTracks.kt`.

Kotlin API exported to Swift (Objective-C rules):
- No public members starting with `new`, `alloc`, `copy`, `mutableCopy` or `init`: Kotlin/Native renames them `do…` (hence `latestReleases`, not `newReleases`).
- Avoid `description` and `hash` as property names (they clash with NSObject), and class names the ObjC runtime already uses (`Category`, hence `BrowseCategory`).
- Callbacks Swift implements are Kotlin interfaces, not lambdas (see `PageLoadCallback`, `ScriptCallback`).
- `suspend fun` becomes `async throws` in Swift. Kotlin `Int` is `Int32`, `Long?` is `KotlinLong?` (`.int64Value`), `Double?` is `KotlinDouble?` (`.doubleValue`).

Swift:
- Swift 5 language mode (the Kotlin types are not `Sendable`); keep it.
- No `await` inside an autoclosure: not on the right of `??`, `&&` or `||`.
- Do not capture a non-escaping closure parameter in an escaping closure (`tabViewBottomAccessory`, `overlay`…): evaluate it into a value first.
- iOS 26-only APIs go behind `if #available(iOS 26, *)`; deployment target is iOS 18.

Playback: AVPlayer only plays AAC in MP4. Streams are requested with `AudioQuality.MP4`, no SABR, no HLS (see `MusicService.resolveStream`).

## House rules

- Never commit `*.zip`, `failed.log`, `xcodebuild.log` (they are in `.gitignore`).
- Credit upstream code in a header comment when porting (`// Ported from BitChord (GPL-3.0): …`).
- No name, logo or artwork of Apple, YouTube or Google in the app's own assets.
