#!/bin/sh
# Actual C static-archive tests; no assertion of a full Pascal application build.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
CC=${CC:-cc}
AR=${AR:-ar}
[ "$(uname -s)" = Linux ] || { echo 'This native guard test requires Linux'; exit 2; }
# Do not let an external test setup supply a mock for the real runtime test.
unset LD_LIBRARY_PATH
CFLAGS='-std=c11 -O1 -g -Wall -Wextra -Werror -Wno-misleading-indentation -fPIC'
if [ "${KVM_SANITIZE:-1}" = 1 ]; then
  CFLAGS="$CFLAGS -fsanitize=address,undefined -fno-omit-frame-pointer"
fi
$CC $CFLAGS -c "$ROOT/native/session/kvm_session_linux.c" -o "$TMP/session.o"
$AR rcs "$TMP/libkvm_session.a" "$TMP/session.o"
$CC $CFLAGS "$ROOT/tests/test_session_runtime.c" "$TMP/libkvm_session.a" -ldl -o "$TMP/runtime"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$TMP/runtime"
python3 "$ROOT/tools/audit_standalone.py" "$TMP/runtime"
# Session states, changes, 1000 open/close cycles, mocked SYSTEM service only.
mkdir "$TMP/mock" "$TMP/broken"
$CC $CFLAGS -shared "$ROOT/tests/session_mock.c" -o "$TMP/mock/libsystemd.so.0"
$CC $CFLAGS "$ROOT/tests/test_session.c" "$TMP/libkvm_session.a" -ldl -o "$TMP/session-test"
LD_LIBRARY_PATH="$TMP/mock" ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$TMP/session-test"
# Present library, missing required symbol: must not crash or tell the user
# to rebuild a nonexistent liblazdesk_session.so in this static test.
printf '%s\n' 'int unrelated_symbol(void) { return 1; }' > "$TMP/broken.c"
$CC $CFLAGS -shared "$TMP/broken.c" -o "$TMP/broken/libsystemd.so.0"
$CC $CFLAGS "$ROOT/tests/test_session_open_error.c" "$TMP/libkvm_session.a" -ldl -o "$TMP/error-test"
LD_LIBRARY_PATH="$TMP/broken" ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$TMP/error-test"
echo 'PASS: native archive tests; this is not a compiled LazDesk server/client.'
