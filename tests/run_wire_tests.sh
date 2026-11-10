#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v fpc >/dev/null 2>&1; then
  echo 'FPC is required to run the wire tests.' >&2
  exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fpc -Fu"$ROOT/shared" -FU"$TMP" -FE"$TMP" "$ROOT/tests/test_wire.lpr" >"$TMP/build.log"
"$TMP/test_wire"
