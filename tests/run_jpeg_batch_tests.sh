#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v fpc >/dev/null 2>&1; then
  echo 'NOT RUN: Free Pascal required for JPEG thread test.' >&2
  exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fpc -O2 -Fu"$ROOT/shared" -Fu"$ROOT/server" -FU"$TMP" -FE"$TMP" \
  "$ROOT/tests/test_jpeg_batch.lpr" >"$TMP/build-jpeg.log" || {
  cat "$TMP/build-jpeg.log" >&2
  exit 1
}
"$TMP/test_jpeg_batch"
