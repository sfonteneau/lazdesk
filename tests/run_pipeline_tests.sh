#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v fpc >/dev/null 2>&1; then
  echo 'NOT RUN: Free Pascal is required for the pipeline tests.' >&2
  exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fpc -Cr -Co -Fu"$ROOT/shared" -FU"$TMP" -FE"$TMP" \
  "$ROOT/tests/test_pipeline_copy.lpr" >"$TMP/copy-build.log" || {
  cat "$TMP/copy-build.log"; exit 1;
}
"$TMP/test_pipeline_copy"
fpc -Cr -Co -Fu"$ROOT/shared" -Fu"$ROOT/client" -FU"$TMP" -FE"$TMP" \
  "$ROOT/tests/test_turbo_client.lpr" >"$TMP/turbo-build.log" || {
  cat "$TMP/turbo-build.log"; exit 1;
}
"$TMP/test_turbo_client" "$ROOT/tests/fixtures/turbo_5x3.jpg"
