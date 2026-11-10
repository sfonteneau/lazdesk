#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
pkg-config --exists gio-2.0 gio-unix-2.0 libpipewire-0.3 || {
  echo 'Install gcc, pkg-config, libglib2.0-dev, libpipewire-0.3-dev and libspa-0.2-dev.' >&2
  exit 2
}
cc -std=c11 -O2 -g -Wall -Wextra -Werror=implicit-function-declaration \
  -fPIC -fvisibility=hidden -shared \
  $(pkg-config --cflags gio-2.0 gio-unix-2.0 libpipewire-0.3) \
  "$ROOT/native/linux/kvm_portal.c" \
  -o "$ROOT/server/liblazdesk_portal.so" \
  $(pkg-config --libs gio-2.0 gio-unix-2.0 libpipewire-0.3) -pthread
