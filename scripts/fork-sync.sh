#!/usr/bin/env bash
#
# fork-sync.sh -- move the NewPipe Audio fork onto a newer upstream NewPipe release.
#
# The fork is kept as a small commit series on branch $FORK_BRANCH sitting directly on top of a
# plain upstream commit. Upgrading therefore means *rebasing* that series onto the new upstream
# release, never merging upstream into the fork branch.
#
# Usage:
#   scripts/fork-sync.sh                  # rebase onto the newest upstream release tag, then build
#   scripts/fork-sync.sh v0.31.0          # rebase onto a specific tag or commit
#   scripts/fork-sync.sh --verify-only    # after a manual conflict resolution: check + build only
#   BASE_REF=v0.29.1 scripts/fork-sync.sh # override the remembered fork base
#   SKIP_BUILD=1 scripts/fork-sync.sh     # do everything except the Gradle build
#   FORCE=1 scripts/fork-sync.sh v0.28.0  # allow a sideways/backwards rebase on purpose
#
# Environment:
#   FORK_BRANCH      branch holding the fork commits            (default: audio-only)
#   UPSTREAM_REMOTE  remote pointing at TeamNewPipe/NewPipe     (default: upstream)
#   BASE_REF         upstream commit the fork branch is based on (default: refs/fork-base
#                    marker, else merge-base with upstream/dev)
#   BUILD_TASK       Gradle task to run                         (default: :app:assembleContinuous)
#   FORCE            set to 1 to rebase onto a target that does not contain the current base
#
# On success the new base is recorded in refs/fork-base so later runs need no arguments.
# On conflict the rebase is left in progress for you to resolve; nothing is recorded.
#
set -euo pipefail

FORK_BRANCH=${FORK_BRANCH:-audio-only}
UPSTREAM_REMOTE=${UPSTREAM_REMOTE:-upstream}
BUILD_TASK=${BUILD_TASK:-:app:assembleContinuous}
BASE_MARKER=refs/fork-base
SKIP_BUILD=${SKIP_BUILD:-0}

VERIFY_ONLY=0
TARGET=""
for arg in "$@"; do
    case "$arg" in
        --verify-only) VERIFY_ONLY=1 ;;
        -h|--help)     sed -n '2,24p' "$0"; exit 0 ;;
        -*)            echo "unknown option: $arg" >&2; exit 2 ;;
        *)             TARGET=$arg ;;
    esac
done

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- verify the fork is intact
# The whole fork hangs on a handful of lines. If a rebase or a conflict resolution drops one of
# them, the app still builds but is silently no longer audio-only, so check them explicitly.
run_checks() {
    local fail=0
    echo "== verifying the audio-only chokepoints =="
    check() { # check <file> <fixed-string> <description>
        if grep -qF -- "$2" "$1" 2>/dev/null; then
            printf '  ok       %s\n' "$3"
        else
            printf '  MISSING  %s  (%s)\n' "$3" "$1"
            fail=1
        fi
    }
    local P=app/src/main/java/org/schabi/newpipe
    check "$P/player/Player.java" 'playerType = PlayerType.AUDIO;' 'Player.handleIntent forces the audio player'
    check "$P/player/Player.java" 'return audioResolver.resolve(info);' 'Player.sourceOf resolves audio only'
    check "$P/util/NavigationHelper.java" 'PlayerType.AUDIO' 'NavigationHelper targets the audio player'
    check "$P/fragments/detail/VideoDetailFragment.java" 'openNormalBackgroundPlayer' 'detail page starts the audio player'
    check "$P/download/DownloadDialog.java" 'isAudioStreamsAvailable' 'download dialog is audio only'
    check app/src/main/res/xml/video_audio_settings.xml 'default_audio_format_key' 'audio settings are present'

    local markers
    markers=$(grep -rc 'AUDIO-ONLY FORK' app/src/main 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
    printf '  markers  %s "AUDIO-ONLY FORK" markers found\n' "$markers"
    [ "$markers" -ge 8 ] || { printf '  MISSING  fork markers vanished - a hunk was probably lost\n'; fail=1; }
    return "$fail"
}

# ---------------------------------------------------------------- rebase onto the new release
if [ "$VERIFY_ONLY" = 0 ]; then
    git fetch --tags --prune "$UPSTREAM_REMOTE"
    if [ -z "$TARGET" ]; then
        TARGET=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)
        [ -n "$TARGET" ] || die "no release tags found on $UPSTREAM_REMOTE"
    fi
    git rev-parse --verify --quiet "$TARGET^{commit}" >/dev/null \
        || die "'$TARGET' is not a valid commit or tag"

    if [ -n "${BASE_REF:-}" ]; then
        BASE=$(git rev-parse --verify "$BASE_REF^{commit}") || die "BASE_REF '$BASE_REF' not found"
        BASE_SOURCE="BASE_REF"
    elif git rev-parse --verify --quiet "$BASE_MARKER" >/dev/null; then
        BASE=$(git rev-parse "$BASE_MARKER^{commit}")
        BASE_SOURCE="recorded marker"
    else
        BASE=$(git merge-base "$FORK_BRANCH" "$UPSTREAM_REMOTE/dev")
        BASE_SOURCE="merge-base with $UPSTREAM_REMOTE/dev (first run)"
    fi

    TARGET_SHA=$(git rev-parse "$TARGET^{commit}")

    if [ "$BASE" = "$TARGET_SHA" ]; then
        echo "already based on $TARGET; nothing to rebase."
        exit 0
    fi

    # Rebasing onto a ref that does not contain the current base moves the fork sideways or
    # backwards, which silently drops it onto older upstream code. Almost always a mistake.
    if ! git merge-base --is-ancestor "$BASE" "$TARGET_SHA"; then
        echo "warning: $TARGET ($(git log -1 --format=%h "$TARGET_SHA")) does not contain the"
        echo "         current fork base ($(git log -1 --format=%h "$BASE")); this would move the"
        echo "         fork onto older upstream code rather than a newer release."
        [ "${FORCE:-0}" = "1" ] || die "refusing to rebase; pass FORCE=1 if you really mean it"
    fi

    # A wrong base makes `git rebase --onto` replay upstream's own commits as if they were yours,
    # duplicating history. A healthy fork has a handful of commits above its base.
    FORK_COMMITS=$(git rev-list --count "$BASE..$FORK_BRANCH")
    if [ "$FORK_COMMITS" -gt 20 ]; then
        echo "warning: $FORK_BRANCH has $FORK_COMMITS commits above the base $(git log -1 --format=%h "$BASE")."
        echo "         That usually means the base is wrong and the rebase would duplicate upstream"
        echo "         commits. Pass BASE_REF=<the commit the fork was based on> to correct it."
        [ "${FORCE:-0}" = "1" ] || die "refusing to rebase; pass FORCE=1 if you really mean it"
    fi

    echo "fork branch : $FORK_BRANCH"
    echo "fork base   : $BASE ($(git log -1 --format=%h\ %s "$BASE" | cut -c1-70)) [$BASE_SOURCE]"
    echo "new base    : $TARGET ($(git log -1 --format=%h\ %s "$TARGET" | cut -c1-70))"
    echo "fork commits: $FORK_COMMITS"
    echo

    git checkout --quiet "$FORK_BRANCH"
    if ! git rebase --onto "$TARGET" "$BASE" "$FORK_BRANCH"; then
        cat <<'EOF'

------------------------------------------------------------------------------------------
Rebase stopped on a conflict. Resolve it, run `git rebase --continue`, then run
`scripts/fork-sync.sh --verify-only` to re-check the fork and rebuild.

What each conflict means and how to resolve it:
  * player/Player.java
        - `sourceOf()`     -> keep the fork: the body must stay `return audioResolver.resolve(info);`
        - `handleIntent()` -> keep the fork: `playerType = PlayerType.AUDIO;` must stay after the
          upstream `IntentCompat.getSerializableExtra(...)` line. If upstream moved where the
          player type is decided, re-apply the assignment at that new place.
  * util/NavigationHelper.java, util/PlayButtonHelper.kt, fragments/detail/VideoDetailFragment.java
        - keep every `PlayerType.AUDIO` / `openNormalBackgroundPlayer(...)` / audio-preference
          hunk. If upstream renamed a helper, port the fork's *intent*, not the old text.
  * download/DownloadDialog.java
        - keep the audio-only `setupDownloadOptions()`; upstream often touches this method, so
          re-apply the removal of the video/subtitle branches rather than merging them.
  * res/xml/video_audio_settings.xml
        - trivial: the fork deletes video preferences. Re-delete any video preference upstream
          just added; keep everything audio or playback related.
  * app/build.gradle.kts
        - keep `applicationId = "org.schabi.newpipe.audio"` and the "NewPipe Audio" app names.
  * Anything you cannot resolve:
        - `git checkout --theirs <file>` takes upstream wholesale and you re-apply the fork edit
          by hand; `git rebase --skip` drops the fork commit; `git rebase --abort` bails out.
------------------------------------------------------------------------------------------
EOF
        exit 1
    fi
fi

# ---------------------------------------------------------------- check, record, build
if ! run_checks; then
    echo
    echo "The fork is not intact. Fix the hunks listed above, amend the fork commit, then re-run"
    echo "with --verify-only. The base marker was NOT updated."
    exit 1
fi

if [ -n "$TARGET" ]; then
    git update-ref "$BASE_MARKER" "$(git rev-parse "$TARGET^{commit}")"
    echo
    echo "fork verified; base marker updated to $TARGET."
fi

if [ "$SKIP_BUILD" = "1" ]; then
    echo "SKIP_BUILD=1 set, not building."
    exit 0
fi

echo
echo "== building $BUILD_TASK =="
./gradlew "$BUILD_TASK" -Dorg.gradle.jvmargs="-Xmx3g -Djava.net.preferIPv4Stack=true" \
    -x runCheckstyle -x runKtlint -x formatKtlint -x checkDependenciesOrder
echo
echo "Done. Check on a device: play -> lock screen -> audio continues, notification controls,"
echo "play queue, a playlist, and that the download dialog only offers audio."
