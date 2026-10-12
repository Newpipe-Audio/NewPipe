# NewPipe Audio

An **audio-only fork of [NewPipe](https://github.com/TeamNewPipe/NewPipe)** — search, stream,
playlists, the play queue and background playback, with the video player, the popup player,
picture-in-picture and video downloads removed.

This is an unofficial personal fork. It is not affiliated with or endorsed by TeamNewPipe.

| | |
|---|---|
| Upstream base | NewPipe 0.29.1 (`dev`) |
| Application id | `org.schabi.newpipe.audio` — installs **alongside** official NewPipe |
| Minimum Android | 7.0 (API 23) |
| Licence | GPL-3.0-or-later, same as upstream |

## What is different from upstream

The fork is deliberately small — **two commits on top of a plain upstream commit**, 8 files,
+50 / −177 lines. Video is removed structurally rather than by deleting UI classes:

* `Player.sourceOf()` always resolves an **audio-only** media source, so no video stream is ever
  fetched or decoded for on-demand content.
* `Player.handleIntent()` always selects `PlayerType.AUDIO` — the only player type that fully
  disables the video renderer and is driven by the media notification. Background playback,
  lock-screen controls and the play queue therefore behave exactly as upstream.
* Every entry point (`NavigationHelper`, `PlayButtonHelper`, `VideoDetailFragment`,
  `RouterActivity`) routes to that player; the popup player and PiP are unreachable.
* Video quality/resolution/PiP preferences are gone from settings; downloads are audio-only.

Every deviation is marked in the source with an `AUDIO-ONLY FORK:` comment — `grep -rn "AUDIO-ONLY FORK" app/`
lists all of them.

Two known limits, both inherited rather than introduced: **live streams** still go through the
shared DASH/HLS path (video is not decoded, but HLS may still fetch some video data), and services
that publish no separate audio streams fall back to a muxed stream so playback keeps working.

## Install

```bash
adb install -r NewPipe-Audio-<version>.apk
```

Release APKs are signed with the standard Android debug keystore, so they are sideloadable but not
upgradeable across differently-signed builds.

## Build

Needs a full **JDK 21** (a JRE fails with `does not provide the required capabilities:
[JAVA_COMPILER]`), Android SDK platform 37 + build-tools 37.0.0.

```bash
echo "sdk.dir=$HOME/android-sdk" > local.properties
./gradlew :app:assembleContinuous \
  -x runCheckstyle -x runKtlint -x formatKtlint -x checkDependenciesOrder
```

`assembleContinuous` is upstream's release-behaviour build type with debug signing, so the result
is directly installable. Add `-Djava.net.preferIPv4Stack=true` to the Gradle JVM args if dependency
downloads crawl (Maven Central and the Gradle Plugin Portal resolve very slowly over IPv6 in some
environments).

## Upgrading from upstream

The fork is rebased onto upstream release tags, never merged with them:

```bash
scripts/fork-sync.sh                 # newest release tag: rebase, self-check, build
scripts/fork-sync.sh v0.31.0         # or pin the tag explicitly
scripts/fork-sync.sh --verify-only   # re-check and rebuild after resolving conflicts by hand
```

The script verifies the audio-only chokepoints survived the rebase before building, and refuses to
rebase onto a tag that does not contain the current base. See the guide for the conflict map.

Separately, and more often than app releases: streaming breakage is fixed upstream in
NewPipeExtractor. Bump the single pin in `gradle/libs.versions.toml`
(`teamnewpipe-newpipe-extractor`) to a newer extractor revision — it does not touch this fork's
changes.

## Documentation

| File | Contents |
|---|---|
| `NewPipe-Audio-Fork-Guide.md` | full architecture map, every change and its rationale, rebuild and upgrade instructions |
| `audio-only-fork.patch` | the complete diff against upstream, applies cleanly to a fresh clone |
| `fork-sync.sh` | upstream upgrade helper (also lives at `scripts/fork-sync.sh`) |

## Licence

GPL-3.0-or-later, inherited from upstream. NewPipe and NewPipeExtractor are © TeamNewPipe and
contributors. Streaming from third-party services remains subject to those services' terms of use.
