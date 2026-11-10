#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v fpc >/dev/null 2>&1 || { echo 'NOT RUN: Free Pascal is required.' >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
compile() {
  fpc -B -Cr -Co -gl -Fu"$ROOT/shared" -Fu"$ROOT/server" -FU"$TMP" -FE"$TMP" \
    "$ROOT/tests/$1.lpr" >"$TMP/$1.log" 2>&1 || { cat "$TMP/$1.log" >&2; exit 1; }
}
compile test_v7_core
"$TMP/test_v7_core"
compile test_frame
"$TMP/test_frame"
for suite in cli wire flow damage turbo; do sh "$ROOT/tests/run_${suite}_tests.sh"; done
if [ "${KVM_TEST_X11:-0}" = 1 ]; then
  compile test_linux_desktop
  # Only on an isolated test display; never inject into the user's real desktop.
  xvfb-run -a -s '-screen 0 640x360x24 -nolisten tcp' "$TMP/test_linux_desktop"
fi
