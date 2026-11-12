#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
  cat <<'HELP'
Usage: sh build/build_macos.sh [--lazbuild /path/to/lazbuild]

  --lazbuild PATH   Lazarus build executable (also: LAZBUILD environment variable)
  -h, --help        Show this help

Builds the server and the Cocoa Viewer, then packages the viewer as:
  dist/macos/LazDeskClient.app
Requires Python 3 for macOS .app packaging.
HELP
}

LAZBUILD_BIN=${LAZBUILD:-lazbuild}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lazbuild)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo 'Missing argument for --lazbuild' >&2; exit 2
      fi
      LAZBUILD_BIN=$2
      shift 2
      ;;
    --lazbuild=*)
      LAZBUILD_BIN=${1#--lazbuild=}
      [ -n "$LAZBUILD_BIN" ] || { echo 'Missing path for --lazbuild' >&2; exit 2; }
      shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v "$LAZBUILD_BIN" >/dev/null 2>&1; then
  echo "lazbuild not found or not executable: $LAZBUILD_BIN" >&2
  echo 'Install Lazarus (Cocoa) and Free Pascal, or set --lazbuild /path/to/lazbuild.' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo 'Python 3 is required to package the macOS .app bundle.' >&2
  exit 2
fi
if [ -n "${MORMOT2_DIR:-}" ]; then
  "$LAZBUILD_BIN" "$MORMOT2_DIR/packages/lazarus/mormot2.lpk"
fi
sh "$ROOT/native/macos/build.sh"
if [ "${KVM_BUILD_CODEC:-0}" = 1 ]; then sh "$ROOT/native/codec/build.sh"; fi
"$LAZBUILD_BIN" "$ROOT/server/LazDeskServer.lpi"
"$LAZBUILD_BIN" --widgetset=cocoa "$ROOT/client/LazDeskClient.lpi"

# A runnable macOS GUI must be launched as a bundle, not as the loose Mach-O
# binary from a shell. Include Info.plist and Lazarus native .po resources.
python3 "$ROOT/build/package_macos_app.py" \
  --executable "$ROOT/client/LazDeskClient" \
  --output "$ROOT/dist/macos/LazDeskClient.app" \
  --languages "$ROOT/client/languages"
