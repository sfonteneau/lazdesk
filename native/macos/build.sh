#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p ../../server
xcrun clang -O2 -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -mmacosx-version-min=12.3 -dynamiclib -fvisibility=hidden \
  -framework Foundation -framework ScreenCaptureKit -framework CoreMedia \
  -framework CoreVideo -framework CoreGraphics \
  -install_name @rpath/liblazdesk_sck.dylib kvm_sck.m \
  -o ../../server/liblazdesk_sck.dylib
