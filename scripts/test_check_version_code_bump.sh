#!/usr/bin/env bash
# Offline tests for scripts/check_version_code_bump.sh.
# No network and no Android SDK needed: --published-version-code and
# --counter-file replace the release APK and the committed counter.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="scripts/check_version_code_bump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
check() {
  local name="$1" expected="$2" counter="$3" published="$4"
  local file="$TMP/$name.properties"
  printf 'versionCode=%s\n' "$counter" > "$file"

  local out status
  set +e
  out="$("$SCRIPT" --counter-file "$file" --published-version-code "$published" 2>&1)"
  status=$?
  set -e

  if [ "$expected" = "pass" ] && [ "$status" -ne 0 ]; then
    echo "FAIL: $name expected pass, got exit $status"
    echo "$out" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
  elif [ "$expected" = "fail" ] && [ "$status" -eq 0 ]; then
    echo "FAIL: $name expected failure, got exit 0"
    echo "$out" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
  fi

  if [ "$expected" = "fail" ]; then
    # The failure must name both numbers, otherwise it cannot be acted on.
    echo "$out" | grep -q "committed versionCode ($counter" \
      || { echo "FAIL: $name message does not name the committed value $counter"; FAILURES=$((FAILURES + 1)); }
    echo "$out" | grep -q "published versionCode ($published" \
      || { echo "FAIL: $name message does not name the published value $published"; FAILURES=$((FAILURES + 1)); }
  fi
}

check "higher-than-published" pass 3600 3265
check "equal-to-published"    fail 3265 3265
check "lower-than-published"  fail 3000 3265
check "one-above-published"   pass 3266 3265

# A missing counter entry must be an error, not a silent pass.
printf 'versionNameOnly=1\n' > "$TMP/broken.properties"
if "$SCRIPT" --counter-file "$TMP/broken.properties" --published-version-code 3265 >/dev/null 2>&1; then
  echo "FAIL: missing versionCode entry was not rejected"
  FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "check_version_code_bump tests FAILED ($FAILURES)"
  exit 1
fi
echo "check_version_code_bump tests passed"
