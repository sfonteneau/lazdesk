#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v lazbuild >/dev/null 2>&1; then
  echo 'Install Lazarus (Cocoa) and Free Pascal first.' >&2
  exit 2
fi
if [ -n "${MORMOT2_DIR:-}" ]; then
  lazbuild "$MORMOT2_DIR/packages/lazarus/mormot2.lpk"
fi
sh "$ROOT/native/macos/build.sh"
# Build the client with the native Cocoa widgetset.
if [ "${KVM_BUILD_CODEC:-0}" = 1 ]; then sh "$ROOT/native/codec/build.sh"; fi
lazbuild "$ROOT/server/LazDeskServer.lpi"
lazbuild --widgetset=cocoa "$ROOT/client/LazDeskClient.lpi"
