#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || { echo 'C compiler missing'; exit 2; }
FLAGS='-std=c11 -O1 -g -Wall -Wextra -Werror -Wno-misleading-indentation -fsanitize=address,undefined -fno-omit-frame-pointer'
$CC $FLAGS "$ROOT/tests/test_h264.c" -o "$TMP/h264"
UBSAN_OPTIONS=halt_on_error=1 ASAN_OPTIONS=detect_leaks=1 "$TMP/h264"
if [ "$(uname -s)" = Linux ]; then
  $CC $FLAGS -fPIC -shared "$ROOT/tests/session_mock.c" -o "$TMP/libsystemd.so.0"
  $CC $FLAGS "$ROOT/native/session/kvm_session_linux.c" "$ROOT/tests/test_session.c" -ldl -o "$TMP/session"
  LD_LIBRARY_PATH="$TMP" UBSAN_OPTIONS=halt_on_error=1 ASAN_OPTIONS=detect_leaks=1 "$TMP/session"
fi
