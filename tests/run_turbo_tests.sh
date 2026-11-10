#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v fpc >/dev/null 2>&1; then
  echo 'FPC is required to run TurboJPEG encoding test.' >&2
  exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fpc -Fu"$ROOT/shared" -Fu"$ROOT/server" -FU"$TMP" -FE"$TMP" \
  "$ROOT/tests/test_turbo.lpr" >"$TMP/build-turbo.log" || {
  cat "$TMP/build-turbo.log" >&2
  exit 1
}
"$TMP/test_turbo"
