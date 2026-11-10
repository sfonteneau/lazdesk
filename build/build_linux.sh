#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v lazbuild >/dev/null 2>&1; then
  echo 'Install Lazarus/lazbuild and Free Pascal first.' >&2
  exit 2
fi
if [ -n "${MORMOT2_DIR:-}" ]; then
  lazbuild "$MORMOT2_DIR/packages/lazarus/mormot2.lpk"
fi
if [ "${KVM_BUILD_PORTAL:-0}" = 1 ]; then
  sh "$ROOT/native/linux/build.sh"
fi
sh "$ROOT/native/session/build.sh"
if [ "${KVM_BUILD_CODEC:-0}" = 1 ]; then sh "$ROOT/native/codec/build.sh"; fi
lazbuild "$ROOT/server/LazDeskServer.lpi"
lazbuild "$ROOT/client/LazDeskClient.lpi"
