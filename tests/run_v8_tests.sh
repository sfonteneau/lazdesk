#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v fpc >/dev/null 2>&1 || { echo 'NOT RUN: Free Pascal required; no Pascal tests executed.' >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fpc -B -Cr -Co -gl -Fu"$ROOT/shared" -Fu"$ROOT/server" -FU"$TMP" -FE"$TMP" \
  "$ROOT/tests/test_v8_core.lpr" >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log" >&2; exit 1; }
"$TMP/test_v8_core"
sh "$ROOT/tests/run_v7_tests.sh"
