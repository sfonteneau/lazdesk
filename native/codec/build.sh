#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
command -v pkg-config >/dev/null 2>&1 || { echo 'pkg-config is required' >&2; exit 2; }
pkg-config --exists libavcodec libavutil libswscale || {
  echo 'NOT BUILT: FFmpeg development libraries libavcodec/libavutil/libswscale are required.' >&2; exit 2;
}
case $(uname -s) in
  Darwin) NAME=liblazdesk_codec.dylib; SHARED=-dynamiclib ;;
  MINGW*|MSYS*) NAME=lazdesk_codec.dll; SHARED=-shared ;;
  *) NAME=liblazdesk_codec.so; SHARED=-shared ;;
esac
FLAGS=''
# Test-only GPL software encoder; not enabled in normal builds.
if [ "${KVM_CODEC_TEST_SOFTWARE:-0}" = 1 ]; then FLAGS=-DKVM_CODEC_TEST_SOFTWARE; fi
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Wno-misleading-indentation -fPIC -fvisibility=hidden \
  $FLAGS $SHARED $(pkg-config --cflags libavcodec libavutil libswscale) \
  "$ROOT/native/codec/kvm_codec.c" $(pkg-config --libs libavcodec libavutil libswscale) \
  -o "$ROOT/server/$NAME"
cp "$ROOT/server/$NAME" "$ROOT/client/$NAME"
