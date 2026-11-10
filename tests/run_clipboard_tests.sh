#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
FPC=${FPC:-fpc}
if ! command -v "$FPC" >/dev/null 2>&1; then
  echo "NOT RUN: FPC missing; clipboard Pascal tests were not executed." >&2
  exit 2
fi
mkdir -p tests/bin/clipboard
for unit in test_clipboard_wire test_clipboard_workers; do
  "$FPC" -B -gl -Cr -Co -Sa -Fushared -Fuclient \
    -FUtests/bin/clipboard -FEtests/bin/clipboard "tests/$unit.lpr"
  "tests/bin/clipboard/$unit"
done
