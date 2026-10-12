# NewPipe Audio — Audio-Only Fork: Build & Modification Guide

**Deliverable:** a sideloadable APK built from upstream NewPipe with all video playback and
video download paths removed, plus the exact patch used to produce it.

| Artifact | Details |
|---|---|
| `NewPipe-Audio-0.29.1.apk` | 11.6 MB, signed (v1/v2), package `org.schabi.newpipe.audio`, label "NewPipe Audio", versionName `0.29.1`, minSdk 23, targetSdk 35, compileSdk 37 |
| `audio-only-fork.patch` | `git diff` against upstream `TeamNewPipe/NewPipe` @ `master` — 8 files, +50 / −177 lines |
| `fork-sync.sh` | maintenance helper: rebases the fork onto a new upstream release, self-checks the audio-only chokepoints, then rebuilds (see §7) |
| Upstream base | `https://github.com/TeamNewPipe/NewPipe` (shallow clone of `master`, NewPipe **0.29.1**, AGP 9.3.1 / Gradle 9.7.1 / Kotlin 2.4.10) |

**SHA-256 of the APK:** `fef9cc32a1b367f62c8d494f2e1299b1b5e163bcd195dc339e295faa7ca9c9c0`

## 1. Installing the APK

```bash
adb install -r NewPipe-Audio-0.29.1.apk
```

Because the application id is `org.schabi.newpipe.audio`, this fork installs **side by side** with
the official NewPipe app (`org.schabi.newpipe`) — no uninstall required, and no clash when the user
later updates upstream. The APK is signed with the standard Android debug keystore, so it is
sideloadable but **not** upgradeable from a differently-signed build; for a real release, supply
your own keystore (see §6).

---

## 2. Architecture map (verified against the 0.29.1 tree)

```
NewPipe (root)
├── app/                    Android application module (all UI + player + download code)
│   └── src/main/java/org/schabi/newpipe/
│       ├── player/
│       │   ├── Player.java              ExoPlayer wrapper, intent handling, renderer control
│       │   ├── PlayerService.java       foreground service that owns the Player
│       │   ├── PlayerType.kt            enum MAIN | AUDIO | POPUP
│       │   ├── resolver/
│       │   │   ├── AudioPlaybackResolver.java   builds a media source from audio streams
│       │   │   ├── VideoPlaybackResolver.java   builds video (+muxed audio) media sources
│       │   │   └── PlaybackResolver.java        shared media-source builders (DASH/HLS/SS/HTTP)
│       │   ├── playback/MediaSourceManager.java queue → StreamInfo → media source
│       │   ├── playqueue/PlayQueue*.java        stream-agnostic queue (no changes needed)
│       │   └── ui/  MainPlayerUi | BackgroundPlayerUi | PopupPlayerUi | VideoPlayerUi
│       ├── fragments/detail/VideoDetailFragment.java   detail page, player surface host
│       ├── download/DownloadDialog.java                download picker (video/audio/subtitles)
│       └── util/ NavigationHelper.java, PlayButtonHelper.kt, ListHelper.java
├── shared/                 KMP shared module (models, extractor wrappers)
├── desktopApp/, iosApp/    non-Android targets (not built for this deliverable)
└── buildSrc/               ProjectConfig.kt — SDK levels, version, application id constant
```

Stream resolution chain that matters for this fork:

```
PlayQueueItem ─▶ Player.sourceOf(item, info)          ← single choke point
                   ├─ audioResolver.resolve(info)      → AudioPlaybackResolver  (audio streams)
                   └─ videoResolver.resolve(info)      → VideoPlaybackResolver  (video streams)
```

`PlayerType.AUDIO` is the key lever: it is the only player type that calls
`player.useVideoAndSubtitles(false)` (in `BackgroundPlayerUi`), which **fully disables the video
renderer**, and it is the only one that is driven by the `MediaStyle` notification + media session
instead of an in-app `SurfaceView`.

---

## 3. What was changed

All changes are marked in the source with an `AUDIO-ONLY FORK:` comment.

### 3.1 Force audio-only stream selection

**`player/Player.java` → `sourceOf(PlayQueueItem, StreamInfo)`**

The three-way branch (audio resolver / conditional audio resolver / video resolver) was replaced by
a single call:

```java
// AUDIO-ONLY FORK: always resolve an audio-only media source.
return audioResolver.resolve(info);
```

This guarantees that `VideoPlaybackResolver` — and therefore `info.getVideoStreams()`,
`info.getVideoOnlyStreams()`, muxed DASH/HLS video manifests and subtitle tracks — is never invoked
for on-demand content. `AudioPlaybackResolver` picks the best filtered audio stream
(`ListHelper.getFilteredAudioStreams` + `getAudioFormatIndex`, honouring the existing "preferred
audio format", "prefer original audio" and "prefer descriptive audio" settings) and hands it to the
shared `PlaybackResolver.buildMediaSource`, which for YouTube synthesises a DASH manifest for that
single audio stream.

**`player/Player.java` → `handleIntent(Intent)`**

```java
playerType = IntentCompat.getSerializableExtra(intent, PLAYER_TYPE, PlayerType.class);
// AUDIO-ONLY FORK: always play with the background (audio) player.
playerType = PlayerType.AUDIO;
```

This is the second safety net: even if an intent still asks for `MAIN` or `POPUP` (deep links,
`FetcherService`, media-button re-entry), the player collapses to `AUDIO`. Consequences:
`initUIsForCurrentPlayerType()` only ever creates `BackgroundPlayerUi`, `isAudioOnly` is always
`true`, and `videoPlayerSelected()` / `popupPlayerSelected()` are permanently `false`.

### 3.2 Player core

* No `MediaItem` is ever built from a video stream (§3.1), so no video track is downloaded or
  decoded for on-demand content.
* `PlayerService` is untouched: it stays a foreground service with `MediaSessionCompat`, so
  **background playback, lock-screen controls, notification actions and the play queue all keep
  working exactly as upstream**.
* The notification is the upstream audio notification (`NotificationPlayerUi` +
  `MediaSessionPlayerUi`): album art, seek bar, queue button — no video layout involved.
* Picture-in-picture and the popup player are unreachable (PiP is only entered from `MainPlayerUi`;
  popup only from `PlayerType.POPUP`).

### 3.3 UI entry points

**`util/NavigationHelper.java`**

* `getPlayerIntent(...)`: default `PLAYER_TYPE` changed from `PlayerType.MAIN` → `PlayerType.AUDIO`.
  Every "play" action in the app (detail page, playlists, long-press menus, external intents) now
  targets the audio player.
* `playOnPopupPlayer(...)`: delegates to `playOnBackgroundPlayer(...)`.
* `enqueueOnPlayer(...)`: always enqueues with `PlayerType.AUDIO`.

**`util/PlayButtonHelper.kt`**: the playlist "popup" button and the popup long-press enqueue now
call the background player.

**`fragments/detail/VideoDetailFragment.java`**

* `openVideoPlayer(...)`: no longer opens the in-app video player. It now honours the *external audio
  player* preference and otherwise starts the background player
  (`openNormalBackgroundPlayer(false)`).
* `isAutoplayEnabled()`: the condition `player.videoPlayerSelected()` became
  `player.audioPlayerSelected()`, so autoplay (e.g. "play all" on a playlist) still works now that
  the player is always in audio mode.
* `isExternalPlayerEnabled()`: switched from the *video* external-player preference to the *audio*
  one, which is the only remaining external-player path.
* The video surface is simply never attached: `tryAddVideoPlayerView()` looks up
  `player.UIs().get(MainPlayerUi.class)` with `ifPresent(...)`, so with no `MainPlayerUi` the player
  placeholder stays empty and the detail page shows the upstream thumbnail + metadata overlay
  (cover art, title, uploader, play/pause, queue button) instead of a video frame.
* Teardown behaviour is a bonus: `onDestroy()` only stops the service when
  `player.videoPlayerSelected()`. With audio-only playback the service is merely unbound, so
  **playback continues when the app is closed**, which is the desired music-player behaviour.

**`RouterActivity.java`** ("open with NewPipe" from other apps): the "video player" choice is now
handled like "show info" when the current player type is `null` or `AUDIO`, and the external-player
check uses the audio preference.

### 3.4 Settings

**`res/xml/video_audio_settings.xml`** — removed (they are no longer reachable and no code uses
`findPreference` on them, so removal is safe):

`default_resolution`, `default_popup_resolution`, `show_higher_resolutions`, `default_video_format`,
`use_external_video_player`, `start_main_player_fullscreen`, `popup_remember_size_pos`,
`seekbar_preview_thumbnail`, and the left/right gesture controls (video gestures).

Kept: mobile data limit, **default audio format**, prefer original / descriptive audio, ExoPlayer
settings, external audio player, Kodi, preferred open action, minimize on exit, autoplay, auto
queue, resume on audio-focus gain, seek options, clear-queue confirmation, hardware media buttons.

### 3.5 Downloads

**`download/DownloadDialog.java` → `setupDownloadOptions()`** — the video and subtitle radio buttons
are hidden and the dialog always selects the audio stream picker. Only **audio downloads** remain;
the download path settings (`DownloadSettingsFragment`) are untouched.

### 3.6 Identity

`app/build.gradle.kts`:

* `applicationId` → `org.schabi.newpipe.audio` (the `namespace` stays `org.schabi.newpipe`, so no
  source-package renaming churn).
* `app_name` → "NewPipe Audio" for every build type; the `debug` variant keeps its `.debug` id
  suffix, and the `continuous` variant no longer adds a `.continuous` suffix.

The launcher icon, the `MainActivity` component name and all other manifests are unchanged.

---

## 4. What was deliberately *not* done

* **Player UI classes were not deleted.** `MainPlayerUi`, `PopupPlayerUi` and `VideoPlayerUi` still
  exist in the tree but are unreachable. Keeping them makes the diff small (50 insertions / 177
  deletions) and keeps future upstream merges tractable. If you want a truly minimal APK, delete
  them and the layouts they bind to — expect a much larger, merge-hostile diff.
* **The "video" wording in the UI was not rewritten.** Strings such as "video player" in the
  "open with" chooser still exist; only their behaviour changed. Rewriting them means touching the
  translation files.
* **Live streams still use DASH/HLS.** `PlaybackResolver.maybeBuildLiveMediaSource()` is shared by
  both resolvers and is the only way to play a live stream. Video is not *decoded* (the video
  renderer is disabled in audio mode), but for HLS the player may still fetch some video data —
  this is the pre-existing ExoPlayer behaviour that upstream comments on
  (`https://github.com/google/ExoPlayer/issues/9282`). Live audio therefore works, but it is not
  guaranteed to be bandwidth-minimal.
* **Services without separate audio streams fall back to a muxed stream.** This is upstream
  `AudioPlaybackResolver` behaviour and was intentionally kept, so playback does not break on
  services that only publish combined streams.
* **No runtime testing.** The build environment has no `/dev/kvm`, so no emulator could be started.
  The APK compiles cleanly (R8 + resource shrinking + lint-vital all pass), is correctly signed, and
  the manifest/label/package were verified with `aapt2`/`apksigner`; **behavioural verification on a
  real device is still outstanding** — install it and check: play a video, lock the screen, verify
  the audio continues and the notification controls work, then check the play queue and a playlist.

---

## 5. Rebuilding

### 5.1 Toolchain (what this build used)

```bash
# JDK 21 (full JDK — a JRE fails with "does not provide the required capabilities: [JAVA_COMPILER]")
sudo apt-get install -y openjdk-21-jdk-headless

# Android SDK command-line tools, then:
sdkmanager --licenses
sdkmanager "platform-tools" "platforms;android-37.0" "build-tools;37.0.0"
```

Gradle itself is supplied by the wrapper (9.7.1, SHA-256 pinned in
`gradle/wrapper/gradle-wrapper.properties`). Point the build at the SDK:

```bash
echo "sdk.dir=$HOME/android-sdk" > local.properties
```

### 5.2 Build commands

```bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export ANDROID_HOME=$HOME/android-sdk

# Installable, minified, signed with the debug keystore (the artifact shipped here):
./gradlew :app:assembleContinuous \
  -x runCheckstyle -x runKtlint -x formatKtlint -x checkDependenciesOrder

# Or a plain debug build (no R8, ~34 MB):
./gradlew :app:assembleDebug \
  -x runCheckstyle -x runKtlint -x formatKtlint -x checkDependenciesOrder
```

Notes:

* `assembleContinuous` is upstream's "release behaviour + debug signing" build type
  (`initWith(release)` + `signingConfig = debug`). `assembleRelease` produces an **unsigned** APK
  because upstream has no release signing config, so it is not directly sideloadable.
* `preDebugBuild` depends on `runCheckstyle` / `runKtlint` / `formatKtlint` / `checkDependenciesOrder`
  (see the `afterEvaluate` block in `app/build.gradle.kts`). They are excluded above for speed; drop
  the `-x` flags if you want the upstream style gate, and keep your edits checkstyle-clean.
* **Network tip:** in this environment Maven Central / the Gradle Plugin Portal resolved over IPv6
  at ~3–90 KB/s. Adding `-Dorg.gradle.jvmargs="… -Djava.net.preferIPv4Stack=true"` raised throughput
  to 1–1.6 MB/s and turned a 30+ minute stall into a 10-minute cold build. No repository mirrors
  were needed in the final build — `settings.gradle.kts` is **unmodified upstream**.

### 5.3 Applying the patch to a fresh clone

```bash
git clone --depth 1 https://github.com/TeamNewPipe/NewPipe.git
cd NewPipe
git apply /path/to/audio-only-fork.patch
```

---

## 6. Shipping a real release

The shipped APK is debug-signed. For distribution, add a release signing config to
`app/build.gradle.kts` (or build `release` with `-PpackageSuffix=…` plus a keystore) and keep the
keystore offline. Since the application id already differs from upstream, you can also publish
alongside official NewPipe builds.

---

## 7. Upgrading to a new NewPipe release

The fork is maintained as a **rebase, not a merge**. It is two commits sitting directly on top of a
plain upstream commit, so an upgrade is one `git rebase --onto` and nothing else.

### 7.1 The model

| Concept | Value |
|---|---|
| Fork branch | `audio-only` — 1 commit with the fork change, 1 with `scripts/fork-sync.sh` |
| Upstream remote | `upstream` -> `https://github.com/TeamNewPipe/NewPipe.git` |
| Fork base | the upstream commit the branch sits on, remembered in `refs/fork-base` |
| Upgrade target | a release tag such as `v0.30.0` — not the moving `dev` branch |

Rules that keep this cheap:

* **Rebase, never merge.** `git merge upstream/dev` pulls the whole video player back in as
  history and makes every future conflict worse. GitHub's "Sync fork" button does exactly that —
  don't use it.
* **Track release tags, not `dev`.** `dev` moves several times a day; a release is the unit worth
  re-validating. (This build happens to sit on a `dev` commit 88 ahead of `v0.29.1`; the next
  upgrade onto a release tag lands cleanly because that tag is a descendant of it.)
* **Never take an upstream hunk just to make a conflict go away.** Re-read it: if it only serves
  video playback, it belongs deleted.

### 7.2 One-time setup

```bash
git clone https://github.com/<you>/NewPipe.git newpipe-audio   # needs real history, not --depth 1
cd newpipe-audio
git remote add upstream https://github.com/TeamNewPipe/NewPipe.git
git fetch --tags upstream

git checkout -b audio-only <the-commit-you-forked-from>
git apply /path/to/audio-only-fork.patch
git add -A && git commit -m "Audio-only fork: play and download audio only, remove video player"
git update-ref refs/fork-base <the-commit-you-forked-from>
```

> A shallow (`--depth 1`) clone **cannot** be rebased — clone normally, or run
> `git fetch --unshallow` first.

### 7.3 Every release

```bash
scripts/fork-sync.sh                 # newest release tag: rebase, self-check, build
scripts/fork-sync.sh v0.31.0         # or pin the tag explicitly
scripts/fork-sync.sh --verify-only   # re-check and rebuild after resolving conflicts by hand
```

The script fetches the tags, rebases the fork branch onto the tag, then **verifies the eight
audio-only chokepoints still exist** — the forced `PlayerType.AUDIO`, `audioResolver.resolve` in
`sourceOf`, `openNormalBackgroundPlayer`, the audio-only download dialog, the audio settings and
the `AUDIO-ONLY FORK` markers — before it builds. It deliberately refuses two dangerous moves:

* rebasing onto a tag that does **not** contain the current base (a sideways or backwards move),
* rebasing when more than 20 commits sit above the base (a wrong base makes `--onto` replay
  upstream's own commits as yours and duplicate history).

Both are overridable with `FORCE=1`. Both were exercised against real history while writing this
guide, along with a simulated next release that touched the same two files, which produced exactly
the conflicts in §7.4.

Optional automation: a scheduled GitHub Action can run `SKIP_BUILD=1 scripts/fork-sync.sh` on a bot
branch on the first of each month and open a PR when it rebases cleanly — worth it only if you want
the fork to track upstream without thinking about it.

### 7.4 What actually conflicts

Only two hunks conflicted in the simulated upgrade, and both resolve mechanically:

| File | Why it conflicts | Resolution |
|---|---|---|
| `player/Player.java` -> `sourceOf()` | the fork deletes the whole resolver-selection chain, so any upstream edit inside it collides | keep the fork body: `return audioResolver.resolve(info);` |
| `res/xml/video_audio_settings.xml` | the fork deletes a run of preferences, so upstream additions next to them collide | drop the new video preference, keep the audio ones |

The rest of the change set — the forced player type, `NavigationHelper`, `PlayButtonHelper`,
`VideoDetailFragment`, `DownloadDialog`, `app/build.gradle.kts` — sits in code upstream rarely
touches and usually rebases silently.

While a rebase is stopped:

```bash
git diff --name-only --diff-filter=U    # list conflicting files
git checkout --theirs <file>            # take upstream wholesale, then re-apply the fork edit
git rebase --continue | --skip | --abort
```

### 7.5 After every upgrade

1. `scripts/fork-sync.sh --verify-only` — the chokepoint self-check must pass.
2. Install and check on a device: play -> lock screen -> **audio keeps playing** with working
   notification controls; play queue and a playlist still work; the download dialog offers audio
   only; the settings screen lists no video options.
3. Re-export the patch if you keep one: `git format-patch refs/fork-base..audio-only -o patches/`.

### 7.6 The more frequent task: the extractor pin

App releases arrive every few weeks, but **streaming breakage does not wait for them**. When a site
changes, upstream fixes NewPipeExtractor first, and that fix does not need a new app release:

```toml
# gradle/libs.versions.toml
teamnewpipe-newpipe-extractor = "65cabc2ba5216ee871ace4a9963c08bdbf5d5dc0"   # <- bump this
```

Bump that single line to the extractor revision current upstream `dev` uses, rebuild, ship. It is
completely independent of the fork rebase and never touches the patch: this fork changes no
extraction, search or service logic, so extractor updates are drop-in. Upstream's own comment above
the pin notes that if JitPack has dropped an artifact you can switch to a commit hash, or nudge the
existing hash, to force regeneration.

If you add your own player work later, keep the two remaining rules from the original design:
logic funnels through `Player.handleIntent` and `Player.sourceOf`, and new UI should be added as
another `PlayerUi` via `UIs.addAndPrepare(...)` rather than by editing `Player.java`.

## 8. Legal / ToS note

NewPipe and NewPipeExtractor are GPL-3.0-or-later; this fork inherits that licence and must keep the
copyright notices and source availability intact. Streaming from third-party services is subject to
those services' terms of use and local law — the same caveat that applies to upstream NewPipe.