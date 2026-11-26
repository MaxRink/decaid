#!/usr/bin/env bash
# Guard: the committed Android versionCode must be strictly greater than the
# versionCode of the most recently published release APK.
#
# Why: android/version.properties is bumped by hand at release time. Nothing in
# the build fails if a maintainer forgets -- the release simply ships a version
# code that Android refuses to install over the previous build. This check turns
# that silent omission into a failing CI job, and it also catches the case where
# a branch was opened long ago and a newer release shipped meanwhile.
#
# Usage:
#   scripts/check_version_code_bump.sh
#   scripts/check_version_code_bump.sh --counter-file path/to/version.properties
#   scripts/check_version_code_bump.sh --published-version-code 3265
#
# Environment:
#   RELEASE_REPO  repository whose releases are the reference (default decentespresso/decaid)
#   GH_TOKEN      token used for the GitHub API; read-only access is enough
set -euo pipefail
cd "$(dirname "$0")/.."

COUNTER_FILE="android/version.properties"
RELEASE_REPO="${RELEASE_REPO:-decentespresso/decaid}"
PUBLISHED_VERSION_CODE=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() {
  echo "versionCode guard: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --counter-file)
      [ $# -ge 2 ] || die "--counter-file needs a path"
      COUNTER_FILE="$2"
      shift 2
      ;;
    --published-version-code)
      [ $# -ge 2 ] || die "--published-version-code needs an integer"
      PUBLISHED_VERSION_CODE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

read_committed_version_code() {
  local file="$1" raw
  [ -f "$file" ] || die "missing $file"
  raw="$(sed -n 's/^versionCode=\([0-9][0-9]*\)$/\1/p' "$file" | head -n 1)"
  [ -n "$raw" ] || die "$file has no 'versionCode=<integer>' entry"
  printf '%s\n' "$raw"
}

find_aapt2() {
  local candidate
  if command -v aapt2 >/dev/null 2>&1; then
    command -v aapt2
    return 0
  fi
  for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [ -n "$sdk_root" ] && [ -d "$sdk_root/build-tools" ] || continue
    # Highest build-tools version wins; aapt2 ships with every modern one.
    candidate="$(find "$sdk_root/build-tools" -maxdepth 2 -type f -name aapt2 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

apk_version_code() {
  local apk="$1" aapt2 badging
  aapt2="$(find_aapt2)" || die "aapt2 not found; set ANDROID_HOME or install Android build-tools"
  badging="$("$aapt2" dump badging "$apk" 2>/dev/null | head -n 1)"
  # shellcheck disable=SC2016 # single quotes are deliberate: this is a sed script
  printf '%s\n' "$badging" | sed -n "s/.*versionCode='\\([0-9][0-9]*\\)'.*/\\1/p"
}

read_published_version_code() {
  command -v gh >/dev/null 2>&1 || die "gh CLI not found; install it or pass --published-version-code"
  local tag asset
  tag="$(gh release list --repo "$RELEASE_REPO" --exclude-pre-releases --limit 1 \
    --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    echo "versionCode guard: no published release found in $RELEASE_REPO; nothing to compare against" >&2
    return 1
  fi
  asset="$(gh release view "$tag" --repo "$RELEASE_REPO" --json assets \
    --jq '[.assets[].name] | map(select(test("^decaid-android-[0-9].*\\.apk$"))) | .[0] // ""' 2>/dev/null || true)"
  if [ -z "$asset" ]; then
    echo "versionCode guard: release $tag in $RELEASE_REPO has no versioned Android APK asset; skipping" >&2
    return 1
  fi
  echo "versionCode guard: reading versionCode from $RELEASE_REPO $tag asset $asset" >&2
  gh release download "$tag" --repo "$RELEASE_REPO" --pattern "$asset" --dir "$TMP" >/dev/null
  apk_version_code "$TMP/$asset"
}

COMMITTED="$(read_committed_version_code "$COUNTER_FILE")"

if [ -n "$PUBLISHED_VERSION_CODE" ]; then
  PUBLISHED="$PUBLISHED_VERSION_CODE"
  SOURCE="--published-version-code (not read from a release APK)"
elif PUBLISHED="$(read_published_version_code)"; then
  SOURCE="latest published release APK"
else
  echo "versionCode guard: SKIPPED (no published Android APK to compare against); committed=$COMMITTED" >&2
  exit 0
fi

[ -n "$PUBLISHED" ] || die "could not determine the published versionCode"

case "$COMMITTED" in
  ''|*[!0-9]*) die "committed versionCode '$COMMITTED' is not a positive integer ($COUNTER_FILE)" ;;
esac
case "$PUBLISHED" in
  ''|*[!0-9]*) die "published versionCode '$PUBLISHED' is not a positive integer" ;;
esac

if [ "$COMMITTED" -le "$PUBLISHED" ]; then
  {
    echo
    echo "FAIL: committed versionCode ($COMMITTED in $COUNTER_FILE) is not greater than"
    echo "      the published versionCode ($PUBLISHED, $SOURCE)."
    echo
    echo "Android refuses to install an APK whose versionCode is lower than the installed"
    echo "one, so shipping this would break in-place updates. Bump the counter in"
    echo "$COUNTER_FILE to at least $((PUBLISHED + 1)) and commit it with the release change."
    echo "See doc/RELEASE.md -> 'Android versionCode'."
    echo
  } >&2
  exit 1
fi

echo "versionCode guard: OK (committed $COMMITTED > published $PUBLISHED, $SOURCE)"
