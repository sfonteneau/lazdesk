#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/server"
${CC:-cc} -std=c11 -O2 -Wall -Wextra -Werror -Wno-misleading-indentation \
  -fPIC -fvisibility=hidden -shared "$ROOT/native/session/kvm_session_linux.c" \
  -ldl -o "$ROOT/server/liblazdesk_session.so"
