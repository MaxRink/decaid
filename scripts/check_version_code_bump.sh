#!/usr/bin/env bash
# Guard: the committed Android versionCode must be strictly greater than the
# versionCode of the highest published release APK, pre-releases included.
#
# Why: android/version.properties is bumped by hand at release time. Nothing in
# the build fails if a maintainer forgets -- the release simply ships a version
# code that Android refuses to install over the previous build. This check turns
# that silent omission into a failing CI job, and it also catches the case where
# a branch was opened long ago and a newer release shipped meanwhile.
#
# Pre-releases are references too. A beta is a normal download on the same
# releases page, and Android compares versionCode against whatever is installed
# on the device -- it has no idea which release channel that build came from.
# Excluding pre-releases therefore leaves a real downgrade undetected.
#
# Nothing here fails open. A missing tool, an auth or network error, a malformed
# response, or a release that carries no versioned APK is an error, not a skip:
# an unread reference is never treated as a satisfied rule. The single skip
# ("this repository publishes no releases at all") needs --allow-skip or
# VERSION_CODE_GUARD_ALLOW_SKIP=1.
#
# Usage:
#   scripts/check_version_code_bump.sh
#   scripts/check_version_code_bump.sh --counter-file path/to/version.properties
#   scripts/check_version_code_bump.sh --published-version-code 3265
#   scripts/check_version_code_bump.sh --allow-skip
#
# Environment:
#   RELEASE_REPO  repository whose releases are the reference (default decentespresso/decaid)
#   GH_TOKEN      token used for the GitHub API; read-only access is enough
#   VERSION_CODE_GUARD_SCAN  how many recent releases to read (default 5, pre-releases included)
#   VERSION_CODE_GUARD_ALLOW_SKIP=1  same as --allow-skip
#
# Exit codes:
#   0  committed > published, or --allow-skip accepted "this repo has no releases"
#   1  committed <= published (the release would be an Android downgrade), or bad usage
#   2  the published versionCode could not be established, so nothing was verified
set -euo pipefail
cd "$(dirname "$0")/.."

COUNTER_FILE="android/version.properties"
RELEASE_REPO="${RELEASE_REPO:-decentespresso/decaid}"
PUBLISHED_VERSION_CODE=""
SCAN_LIMIT="${VERSION_CODE_GUARD_SCAN:-5}"
ALLOW_SKIP="${VERSION_CODE_GUARD_ALLOW_SKIP:-0}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() {
  echo "versionCode guard: $*" >&2
  exit 1
}

# A reference that cannot be established is an error, never a pass.
die_unavailable() {
  echo "versionCode guard: $*" >&2
  exit 2
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
    --allow-skip)
      ALLOW_SKIP=1
      shift
      ;;
    -h|--help)
      # Everything in the leading comment block, minus the '#' markers.
      sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$SCAN_LIMIT" in
  ''|*[!0-9]*|0) die "VERSION_CODE_GUARD_SCAN must be a positive integer, got '$SCAN_LIMIT'" ;;
esac

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

# Prints the versionCode of one APK, or returns 1 (the reason goes to stderr).
apk_version_code() {
  local aapt2="$1" apk="$2" badging
  [ -f "$apk" ] || {
    echo "versionCode guard: $apk was not downloaded" >&2
    return 1
  }
  # Deliberately no `| head -n 1`: with pipefail, a reader that exits early can
  # kill aapt2 with SIGPIPE and turn a good read into a failure.
  if ! badging="$("$aapt2" dump badging "$apk" 2>/dev/null)"; then
    echo "versionCode guard: aapt2 could not dump $apk" >&2
    return 1
  fi
  # shellcheck disable=SC2016 # single quotes are deliberate: this is a sed script
  printf '%s\n' "${badging%%$'\n'*}" | sed -n "s/.*versionCode='\([0-9][0-9]*\)'.*/\1/p"
}

# Reads the versionCode of the newest published release APKs -- pre-releases
# included, see the header -- and prints the highest as
# "<versionCode>\t<tag>\t<asset>\t<releases read>".
#
# Returns instead of exiting, so that the *caller* owns the policy and no `die`
# here can be swallowed by a command substitution:
#   0  a published versionCode was read
#   1  provably nothing to compare against: $RELEASE_REPO publishes no releases
#   2  error: tooling missing, auth/network failure, malformed response, or no
#      versioned APK asset in any release that does exist
read_published_version_code() {
  local err="$TMP/gh.err" listing tag asset line candidates=""
  local aapt2 apk code best="" best_tag="" best_asset="" scanned=0

  if ! command -v gh >/dev/null 2>&1; then
    {
      echo "versionCode guard: gh CLI not found, so the published versionCode cannot be read."
      echo "  Fix: install GitHub CLI (https://cli.github.com), or pass --published-version-code <n>."
    } >&2
    return 2
  fi

  # No --exclude-pre-releases: a pre-release APK is installed on real devices,
  # so it is a reference like any other release.
  if ! listing="$(gh release list --repo "$RELEASE_REPO" --limit "$SCAN_LIMIT" \
      --json tagName --jq '.[].tagName' 2>"$err")"; then
    {
      echo "versionCode guard: gh could not list the releases of $RELEASE_REPO."
      echo "  Check GH_TOKEN (read access is enough), the network, and RELEASE_REPO. gh said:"
      sed 's/^/    /' "$err"
    } >&2
    return 2
  fi
  if [ -z "$listing" ]; then
    echo "versionCode guard: $RELEASE_REPO publishes no releases, so there is no published versionCode to compare against." >&2
    return 1
  fi

  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if ! asset="$(gh release view "$tag" --repo "$RELEASE_REPO" --json assets \
        --jq '[.assets[].name] | map(select(test("^decaid-android-[0-9].*\\.apk$"))) | .[0] // ""' 2>"$err")"; then
      {
        echo "versionCode guard: gh could not read the assets of $RELEASE_REPO $tag."
        echo "  Check GH_TOKEN, the network, and RELEASE_REPO. gh said:"
        sed 's/^/    /' "$err"
      } >&2
      return 2
    fi
    if [ -z "$asset" ]; then
      echo "versionCode guard: $RELEASE_REPO $tag ships no decaid-android-<version>.apk asset; it cannot be a reference" >&2
      continue
    fi
    printf -v line '%s\t%s\n' "$tag" "$asset"
    candidates+="$line"
  done <<< "$listing"

  if [ -z "$candidates" ]; then
    {
      echo "versionCode guard: none of the $RELEASE_REPO releases in the scan window ships a"
      echo "  decaid-android-<version>.apk asset, so there is no published versionCode to compare"
      echo "  against (releases seen: ${listing//$'\n'/ })."
      echo "  Fix: point RELEASE_REPO at the repository that publishes the APK, or pass --published-version-code <n>."
    } >&2
    return 2
  fi

  if ! aapt2="$(find_aapt2)"; then
    {
      echo "versionCode guard: aapt2 not found, so the published versionCode cannot be read."
      echo "  Fix: set ANDROID_HOME (or ANDROID_SDK_ROOT) to an SDK with build-tools installed"
      echo "  (sdkmanager --install 'build-tools;35.0.0'), or pass --published-version-code <n>."
    } >&2
    return 2
  fi

  while IFS=$'\t' read -r tag asset; do
    [ -n "$tag" ] || continue
    if ! gh release download "$tag" --repo "$RELEASE_REPO" --pattern "$asset" \
        --dir "$TMP/dl/$tag" 2>"$err"; then
      {
        echo "versionCode guard: gh could not download $asset from $RELEASE_REPO $tag."
        echo "  Check GH_TOKEN, the network, and the release assets. gh said:"
        sed 's/^/    /' "$err"
      } >&2
      return 2
    fi
    apk="$TMP/dl/$tag/$asset"
    if ! code="$(apk_version_code "$aapt2" "$apk")" || [ -z "$code" ]; then
      echo "versionCode guard: could not read a versionCode from $RELEASE_REPO $tag asset $asset; refusing to compare against a guess." >&2
      return 2
    fi
    scanned=$((scanned + 1))
    echo "versionCode guard: $RELEASE_REPO $tag asset $asset -> versionCode $code" >&2
    if [ -z "$best" ] || [ "$code" -gt "$best" ]; then
      best="$code"
      best_tag="$tag"
      best_asset="$asset"
    fi
  done <<< "$candidates"

  printf '%s\t%s\t%s\t%s\n' "$best" "$best_tag" "$best_asset" "$scanned"
}

COMMITTED="$(read_committed_version_code "$COUNTER_FILE")"

if [ -n "$PUBLISHED_VERSION_CODE" ]; then
  PUBLISHED="$PUBLISHED_VERSION_CODE"
  SOURCE="--published-version-code (not read from a release APK)"
else
  # Capture the output and the status separately: a status that only exists
  # inside $( ) is what made this guard fail open.
  REFERENCE_STATUS=0
  REFERENCE="$(read_published_version_code)" || REFERENCE_STATUS=$?
  PUBLISHED=""
  PUBLISHED_TAG=""
  PUBLISHED_ASSET=""
  PUBLISHED_COUNT="0"
  case "$REFERENCE_STATUS" in
    0)
      IFS=$'\t' read -r PUBLISHED PUBLISHED_TAG PUBLISHED_ASSET PUBLISHED_COUNT <<< "$REFERENCE" || true
      SOURCE="highest of $PUBLISHED_COUNT published release APK(s) in $RELEASE_REPO, pre-releases included ($PUBLISHED_TAG: $PUBLISHED_ASSET)"
      ;;
    1)
      if [ "$ALLOW_SKIP" = "1" ]; then
        echo "versionCode guard: SKIPPED on request: $RELEASE_REPO publishes no releases, so there is nothing a user could have installed. committed=$COMMITTED" >&2
        exit 0
      fi
      die_unavailable "refusing to guess: $RELEASE_REPO publishes no releases, so the guard cannot tell whether committed=$COMMITTED would be a downgrade -- nothing was verified. If this repository has genuinely never published an APK, re-run with --allow-skip or VERSION_CODE_GUARD_ALLOW_SKIP=1."
      ;;
    *)
      die_unavailable "refusing to guess: the published versionCode of $RELEASE_REPO could not be read (see the error above), so committed=$COMMITTED was not verified. Fix the cause, or pass --published-version-code <n> to state the reference explicitly. --allow-skip does not cover this case."
      ;;
  esac
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
