#!/usr/bin/env bash
# Offline tests for scripts/check_version_code_bump.sh.
#
# No network and no Android SDK needed. Two layers:
#   1. arithmetic: --published-version-code and --counter-file replace the
#      release APK and the committed counter;
#   2. fail-open: stub `gh` and stub `aapt2` on a sanitized PATH reproduce a
#      missing tool, an auth error, a release without a versioned APK and a
#      repository with no releases. Every one of them asserts the exit status,
#      because "printed a warning and exited 0" is the defect these guard.
#
# GUARD_SCRIPT runs the suite against another copy of the guard; the mutation
# check in the PR description uses it to prove these tests are load-bearing.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="${GUARD_SCRIPT:-scripts/check_version_code_bump.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CASES=0
FAILURES=0

fail() {
  echo "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------- stubs ----
# A sanitized PATH: only these directories, so a real gh/aapt2 on the host
# cannot turn a "tool missing" test into a false pass.
STUB_DIR="$TMP/fixtures"        # what the stubs read
BIN_GH="$TMP/bin-gh"            # stub gh
BIN_AAPT="$TMP/bin-aapt2"       # stub aapt2
MINBIN="$TMP/minbin"            # the ordinary tools the guard needs

mkdir -p "$STUB_DIR" "$BIN_GH" "$BIN_AAPT" "$MINBIN"
: > "$STUB_DIR/releases"
export STUB_DIR # the stub gh reads its fixtures from here, even under `env PATH=...`

for tool in bash cat dirname env find grep head mkdir mktemp rm sed sort tail; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$src" ]; then
    ln -sf "$src" "$MINBIN/$tool"
  fi
done

cat > "$BIN_GH/gh" <<'STUB_GH'
#!/usr/bin/env bash
# Stub `gh`. Reads $STUB_DIR:
#   releases   "<tag>\t<asset>\t<versionCode>" per release, newest first
#   list_fail  printed by `release list`, which then fails
#   view_fail  printed by `release view`, which then fails
#   dl_fail    printed by `release download`, which then fails
set -u
cmd="${1:-}"
shift || true
if [ "$cmd" != "release" ]; then
  echo "stub gh: unsupported command: $cmd" >&2
  exit 1
fi
sub="${1:-}"
shift || true

field() { # <tag> <1|2|3> -> prints that field of the fixture line
  local t a c
  while IFS=$'\t' read -r t a c; do
    if [ "$t" = "$1" ]; then
      case "$2" in
        1) printf '%s\n' "$t" ;;
        2) [ -z "$a" ] || printf '%s\n' "$a" ;;
        3) printf '%s\n' "$c" ;;
      esac
      return 0
    fi
  done < "$STUB_DIR/releases"
  return 1
}

case "$sub" in
  list)
    if [ -f "$STUB_DIR/list_fail" ]; then
      cat "$STUB_DIR/list_fail" >&2
      exit 1
    fi
    while IFS=$'\t' read -r t a c; do printf '%s\n' "$t"; done < "$STUB_DIR/releases"
    ;;
  view)
    if [ -f "$STUB_DIR/view_fail" ]; then
      cat "$STUB_DIR/view_fail" >&2
      exit 1
    fi
    # Emulate the guard's --jq asset filter: only a versioned APK matches, so a
    # release carrying other assets is reported as having none.
    asset="$(field "${1:-}" 2)" || exit 1
    case "$asset" in
      decaid-android-[0-9]*.apk) printf '%s\n' "$asset" ;;
      *) : ;;
    esac
    ;;
  download)
    tag="${1:-}"
    pattern=""
    dir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --pattern) pattern="$2"; shift 2 ;;
        --dir) dir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -f "$STUB_DIR/dl_fail" ]; then
      cat "$STUB_DIR/dl_fail" >&2
      exit 1
    fi
    code="$(field "$tag" 3)" || exit 1
    mkdir -p "$dir"
    printf 'versionCode=%s\n' "$code" > "$dir/$pattern"
    ;;
  *)
    echo "stub gh: unsupported subcommand: $sub" >&2
    exit 1
    ;;
esac
STUB_GH

cat > "$BIN_AAPT/aapt2" <<'STUB_AAPT'
#!/usr/bin/env bash
# Stub aapt2: prints a badging line carrying the versionCode written into the
# fake APK. A fake APK without one fails, like a truncated download would.
set -u
if [ "${1:-}" != "dump" ] || [ "${2:-}" != "badging" ]; then
  echo "stub aapt2: unsupported call" >&2
  exit 1
fi
file="${3:-}"
code="$(sed -n 's/^versionCode=\([0-9][0-9]*\)$/\1/p' "$file" 2>/dev/null)"
if [ -z "$code" ]; then
  echo "ERROR: Failed to dump badging for '$file'" >&2
  exit 1
fi
printf "package: name='net.tadel.reaprime' versionCode='%s' versionName='0.9.3' compileSdkVersion='36'\n" "$code"
STUB_AAPT
chmod +x "$BIN_GH/gh" "$BIN_AAPT/aapt2"

PATH_TOOLS="$BIN_GH:$BIN_AAPT:$MINBIN"  # gh + aapt2 present
PATH_NO_AAPT2="$BIN_GH:$MINBIN"         # gh present, aapt2 absent
PATH_NO_GH="$BIN_AAPT:$MINBIN"          # aapt2 present, gh absent

# write_releases "<tag>:<asset>:<versionCode>" ... (newest first)
write_releases() {
  : > "$STUB_DIR/releases"
  local spec rest
  for spec in "$@"; do
    rest="${spec#*:}"
    printf '%s\t%s\t%s\n' "${spec%%:*}" "${rest%%:*}" "${rest#*:}" >> "$STUB_DIR/releases"
  done
}
rm -f "$STUB_DIR"/*_fail

OUT=""
STATUS=0

# run_guard <env assignments...> <command...>
run_guard() {
  set +e
  OUT="$(env "$@" 2>&1)"
  STATUS=$?
  set -e
}

expect_status() { # <name> <expected exit status>
  CASES=$((CASES + 1))
  if [ "$STATUS" -ne "$2" ]; then
    fail "$1: expected exit $2, got $STATUS"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
}

expect_output() { # <name> <literal text that must appear>
  if ! printf '%s\n' "$OUT" | grep -qF -- "$2"; then
    fail "$1: output does not say '$2'"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
}

counter() { # <name> <value> -> prints the path
  local file="$TMP/$1.properties"
  printf 'versionCode=%s\n' "$2" > "$file"
  printf '%s\n' "$file"
}

C3600="$(counter committed-3600 3600)"
C3266="$(counter committed-3266 3266)"
C3301="$(counter committed-3301 3301)"

# ----------------------------------------------------------- arithmetic ----
check() { # <name> <pass|fail> <counter> <published>
  local name="$1" expected="$2" file
  file="$(counter "$name" "$3")"
  run_guard PATH="$PATH_TOOLS" "$SCRIPT" --counter-file "$file" --published-version-code "$4"

  if [ "$expected" = "pass" ]; then
    expect_status "$name" 0
  else
    expect_status "$name" 1
    # The failure must name both numbers, otherwise it cannot be acted on.
    expect_output "$name" "committed versionCode ($3"
    expect_output "$name" "published versionCode ($4"
  fi
}

check "higher-than-published" pass 3600 3265
check "equal-to-published"    fail 3265 3265
check "lower-than-published"  fail 3000 3265
check "one-above-published"   pass 3266 3265

# A missing counter entry must be an error, not a silent pass.
printf 'versionNameOnly=1\n' > "$TMP/broken.properties"
run_guard PATH="$PATH_TOOLS" "$SCRIPT" --counter-file "$TMP/broken.properties" --published-version-code 3265
expect_status "missing-versionCode-entry" 1

# ------------------------------------------------------- fail-open cases ----
# Every case below is one the old script turned into "SKIPPED ... exit 0".

# 1. aapt2 missing: the reference cannot be read, so nothing was verified.
write_releases "v0.9.3:decaid-android-0.9.3.apk:3265"
run_guard PATH="$PATH_NO_AAPT2" ANDROID_HOME= ANDROID_SDK_ROOT= GH_TOKEN=x \
  "$SCRIPT" --counter-file "$C3600"
expect_status "aapt2-missing" 2
expect_output "aapt2-missing" "aapt2 not found"
expect_output "aapt2-missing" "ANDROID_HOME"

# 2. gh missing: likewise, and --allow-skip must NOT rescue it.
run_guard PATH="$PATH_NO_GH" GH_TOKEN=x "$SCRIPT" --counter-file "$C3600"
expect_status "gh-missing" 2
expect_output "gh-missing" "gh CLI not found"
run_guard PATH="$PATH_NO_GH" GH_TOKEN=x "$SCRIPT" --counter-file "$C3600" --allow-skip
expect_status "gh-missing-with-allow-skip" 2

# 3. bad GH_TOKEN / API error: an auth failure is not "no releases published".
printf 'HTTP 401: Bad credentials (https://api.github.com/graphql)\n' > "$STUB_DIR/list_fail"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=expired "$SCRIPT" --counter-file "$C3600"
expect_status "gh-auth-error" 2
expect_output "gh-auth-error" "GH_TOKEN"
expect_output "gh-auth-error" "HTTP 401: Bad credentials"
rm -f "$STUB_DIR/list_fail"

# 4. a repository whose releases carry no versioned APK (RELEASE_REPO=cli/cli).
write_releases "v2.40.0:gh_2.40.0_linux_amd64.tar.gz:0" "v2.39.0:gh_2.39.0_linux_amd64.tar.gz:0"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x RELEASE_REPO=cli/cli "$SCRIPT" --counter-file "$C3600"
expect_status "release-without-versioned-apk" 2
expect_output "release-without-versioned-apk" "no decaid-android"

# 5. a repository with no releases at all: unknown must not equal safe.
write_releases
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3600"
expect_status "no-releases-fails-closed" 2
expect_output "no-releases-fails-closed" "refusing to guess"

# ... unless skipping is explicitly opted into, in both spellings.
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3600" --allow-skip
expect_status "no-releases-allow-skip-flag" 0
expect_output "no-releases-allow-skip-flag" "SKIPPED on request"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x VERSION_CODE_GUARD_ALLOW_SKIP=1 \
  "$SCRIPT" --counter-file "$C3600"
expect_status "no-releases-allow-skip-env" 0

# 6. A malformed download must not be read as "no published versionCode".
write_releases "v0.9.3:decaid-android-0.9.3.apk:not-a-number"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3600"
expect_status "unparsable-apk" 2
expect_output "unparsable-apk" "refusing to compare against a guess"

# 7. A failing download must not be read as "nothing to compare against".
write_releases "v0.9.3:decaid-android-0.9.3.apk:3265"
printf 'HTTP 502: Bad Gateway\n' > "$STUB_DIR/dl_fail"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3600"
expect_status "download-failure" 2
expect_output "download-failure" "could not download"
rm -f "$STUB_DIR/dl_fail"

# ------------------------------------------------- pre-releases count too ----
# A beta can carry a higher versionCode than the newest stable. A user who
# installed it cannot take a lower-versioned stable, so the beta is the
# reference -- this is the hole the old --exclude-pre-releases left open.
write_releases "v0.9.4-beta.1:decaid-android-0.9.4-beta.1.apk:3300" \
               "v0.9.3:decaid-android-0.9.3.apk:3265"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3266"
expect_status "pre-release-higher-than-stable-is-caught" 1
expect_output "pre-release-higher-than-stable-is-caught" "published versionCode (3300"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3301"
expect_status "pre-release-higher-than-stable-after-bump" 0

# The published releases of decentespresso/decaid have the opposite shape: the
# newest stable is the highest, pre-releases included.
write_releases "v0.9.3:decaid-android-0.9.3.apk:3265" \
               "v0.9.3-beta.2:decaid-android-0.9.3-beta.2.apk:3244"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3266"
expect_status "stable-higher-than-prerelease" 0
expect_output "stable-higher-than-prerelease" "highest of 2 published release APK(s)"

# A release without a versioned APK inside the window is skipped, not fatal,
# as long as another release can serve as the reference.
write_releases "v0.9.4:decaid-android-latest.apk:0" "v0.9.3:decaid-android-0.9.3.apk:3265"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" --counter-file "$C3600"
expect_status "newest-release-without-apk-falls-back" 0
expect_output "newest-release-without-apk-falls-back" "v0.9.3: decaid-android-0.9.3.apk"

# The reference is the highest versionCode read, not the first (newest) release:
# an older release with a higher code still blocks a lower counter.
write_releases "v0.9.4-beta.1:decaid-android-0.9.4-beta.1.apk:3100" \
               "v0.9.3:decaid-android-0.9.3.apk:3265"
run_guard PATH="$PATH_TOOLS" GH_TOKEN=x "$SCRIPT" \
  --counter-file "$(counter committed-3200 3200)"
expect_status "older-release-with-higher-code-wins" 1
expect_output "older-release-with-higher-code-wins" "published versionCode (3265"

# ------------------------------------------------------------- summary ----
if [ "$FAILURES" -ne 0 ]; then
  echo "check_version_code_bump tests FAILED ($FAILURES failed out of $CASES cases)"
  exit 1
fi
echo "check_version_code_bump tests passed ($CASES cases)"
