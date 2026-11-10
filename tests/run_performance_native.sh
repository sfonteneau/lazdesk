#!/bin/sh
# Actual converter regression with ASan/UBSan; no desktop or GPU required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || { echo 'NOT RUN: C compiler missing' >&2; exit 2; }
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer \
  -fsanitize=address,undefined "$ROOT/tests/test_perf_pixels.c" -o "$TMP/test_perf_pixels"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$TMP/test_perf_pixels"
