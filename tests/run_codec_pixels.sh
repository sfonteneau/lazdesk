#!/bin/sh
# Builds the bridge for testing only, never installs/replaces production DLLs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v pkg-config >/dev/null 2>&1 || \
   ! pkg-config --exists libavcodec libavutil libswscale; then
  echo 'NOT RUN: FFmpeg development libraries required' >&2
  exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -O1 -g -Wall -Wextra -Wno-misleading-indentation \
  -DKVM_CODEC_TEST_SOFTWARE -fno-omit-frame-pointer -fsanitize=address,undefined \
  $(pkg-config --cflags libavcodec libavutil libswscale) \
  "$ROOT/native/codec/kvm_codec.c" "$ROOT/tests/test_codec_pixels.c" \
  $(pkg-config --libs libavcodec libavutil libswscale) -o "$TMP/test_codec_pixels"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$TMP/test_codec_pixels"
