#!/bin/sh
set -eu
unset LAZDESK_TOKEN LAZDESK_VIEW_TOKEN
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v fpc >/dev/null 2>&1; then
  echo 'Free Pascal (fpc) is required to run the CLI tests.' >&2
  exit 2
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fpc -Fu"$ROOT/shared" -FU"$TMP" -FE"$TMP" "$ROOT/tests/test_server_options.lpr" >"$TMP/fpc-server.log"
fpc -Fu"$ROOT/shared" -FU"$TMP" -FE"$TMP" "$ROOT/tests/test_client_options.lpr" >"$TMP/fpc-client.log"
TOKEN=123456789abcdef0123456789abcdef0
OUTPUT=$(env -u LAZDESK_TOKEN "$TMP/test_server_options" --listen 0.0.0.0 --allow-insecure --port=7901 --token "$TOKEN" --fps 5 --quality 75 --control)
printf '%s\n' "$OUTPUT" | grep -q '^LISTEN=0.0.0.0$'
printf '%s\n' "$OUTPUT" | grep -q '^PORT=7901$'
printf '%s\n' "$OUTPUT" | grep -q '^FPS=5$'
printf '%s\n' "$OUTPUT" | grep -q '^QUALITY=75$'
printf '%s\n' "$OUTPUT" | grep -q '^CONTROL=1$'
VIEWTOKEN=abcdef0123456789abcdef0123456789
OUTPUT=$(env -u LAZDESK_TOKEN "$TMP/test_server_options" --control --token "$TOKEN" --view-token "$VIEWTOKEN")
printf '%s\n' "$OUTPUT" | grep -q '^VIEWTOKENLEN=32$'
if env -u LAZDESK_TOKEN "$TMP/test_server_options" --token "$TOKEN" --view-token "$VIEWTOKEN" >/dev/null 2>&1; then
  echo 'View token unexpectedly accepted without control enabled' >&2
  exit 1
fi
if env -u LAZDESK_TOKEN "$TMP/test_server_options" --control --token "$TOKEN" --view-token "$TOKEN" >/dev/null 2>&1; then
  echo 'Identical view/control tokens unexpectedly accepted' >&2
  exit 1
fi
OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options")
printf '%s\n' "$OUTPUT" | grep -q '^LISTEN=127.0.0.1$'
printf '%s\n' "$OUTPUT" | grep -q '^PORT=7900$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXWIDTH=32768$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXHEIGHT=32768$'
OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --adaptive)
printf '%s\n' "$OUTPUT" | grep -q '^ADAPTIVE=1$'
OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --max-width 16000 --max-height 4000)
printf '%s\n' "$OUTPUT" | grep -q '^MAXWIDTH=16000$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXHEIGHT=4000$'
OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --max-width 16000 --native-resolution)
printf '%s\n' "$OUTPUT" | grep -q '^MAXWIDTH=32768$'
OUTPUT=$(env -u LAZDESK_TOKEN "$TMP/test_client_options" --host 192.168.1.50 --port 7901 --token "$TOKEN" --tls)
printf '%s\n' "$OUTPUT" | grep -q '^TLS=1$'
printf '%s\n' "$OUTPUT" | grep -q '^HOST=192.168.1.50$'
printf '%s\n' "$OUTPUT" | grep -q '^AUTOCONNECT=1$'
OUTPUT=$(env -u LAZDESK_TOKEN "$TMP/test_client_options")
printf '%s\n' "$OUTPUT" | grep -q '^AUTOCONNECT=0$'
printf '%s\n' "$OUTPUT" | grep -q '^AUTOCONTROL=0$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXIMIZED=1$'
OUTPUT=$(env -u LAZDESK_TOKEN "$TMP/test_client_options" --host 192.168.1.50 --token "$TOKEN" --control --windowed)
printf '%s\n' "$OUTPUT" | grep -q '^AUTOCONNECT=1$'
printf '%s\n' "$OUTPUT" | grep -q '^AUTOCONTROL=1$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXIMIZED=0$'
OUTPUT=$(env -u LAZDESK_TOKEN "$TMP/test_client_options" --auto-control --windowed --maximized)
printf '%s\n' "$OUTPUT" | grep -q '^AUTOCONTROL=1$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXIMIZED=1$'
if env -u LAZDESK_TOKEN "$TMP/test_server_options" --listen 300.1.2.3 --token "$TOKEN" >/dev/null 2>&1; then
  echo 'Invalid IPv4 unexpectedly accepted' >&2
  exit 1
fi
if env -u LAZDESK_TOKEN "$TMP/test_server_options" --port 70000 --token "$TOKEN" >/dev/null 2>&1; then
  echo 'Invalid port unexpectedly accepted' >&2
  exit 1
fi
if env -u LAZDESK_TOKEN "$TMP/test_server_options" --tls-key only.pem --token "$TOKEN" >/dev/null 2>&1; then
  echo 'TLS key accepted without certificate' >&2
  exit 1
fi
if env -u LAZDESK_TOKEN "$TMP/test_server_options" --token short >/dev/null 2>&1; then
  echo 'Invalid token unexpectedly accepted' >&2
  exit 1
fi
if env -u LAZDESK_TOKEN "$TMP/test_client_options" --host 'http://bad' --token "$TOKEN" >/dev/null 2>&1; then
  echo 'Invalid client host unexpectedly accepted' >&2
  exit 1
fi
OUTPUT=$(env -u LAZDESK_TOKEN -u LAZDESK_VIEW_TOKEN "$TMP/test_server_options" --list-monitors)
printf '%s\n' "$OUTPUT" | grep -q '^LISTMONITORS=1$'
printf '%s\n' "$OUTPUT" | grep -q '^ADAPTIVE=0$'
OUTPUT=$(env -u LAZDESK_VIEW_TOKEN LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --monitor=2 --max-width 3840 --max-height=2160 --fps 30 --no-adaptive)
printf '%s\n' "$OUTPUT" | grep -q '^MONITOR=2$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXWIDTH=3840$'
printf '%s\n' "$OUTPUT" | grep -q '^MAXHEIGHT=2160$'
printf '%s\n' "$OUTPUT" | grep -q '^FPS=30$'
printf '%s\n' "$OUTPUT" | grep -q '^ADAPTIVE=0$'
OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --fps 0 --quality 100 --no-adaptive)
printf '%s\n' "$OUTPUT" | grep -q '^FPS=0$'
printf '%s\n' "$OUTPUT" | grep -q '^QUALITY=100$'
printf '%s\n' "$OUTPUT" | grep -q '^ADAPTIVE=0$'
OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --fps 144 --quality 95)
printf '%s\n' "$OUTPUT" | grep -q '^FPS=144$'
printf '%s\n' "$OUTPUT" | grep -q '^QUALITY=95$'
for BAD in '--fps 1001' '--fps -1' '--quality 0' '--quality 101' '--monitor -1' '--monitor 65' '--max-width 63' '--max-height 32769' '--max-width 32769'; do
  # Intentional word splitting: each BAD fixture contains separate arguments.
  if env -u LAZDESK_VIEW_TOKEN LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" $BAD >/dev/null 2>&1; then
    echo "Invalid options unexpectedly accepted: $BAD" >&2; exit 1
  fi
done
printf '%s\n' "$OUTPUT" | grep -q '^BACKEND=auto$'
for BACKEND in auto x11 portal gdi dxgi sck; do
  OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --backend "$BACKEND")
  printf '%s\n' "$OUTPUT" | grep -q "^BACKEND=$BACKEND$"
done
if env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --backend invalid >/dev/null 2>&1; then
  echo 'Invalid backend unexpectedly accepted' >&2; exit 1
fi
echo 'OK: server/client CLI, backend selection, monitor/profile flags and invalid inputs'

if env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --listen 0.0.0.0 >/dev/null 2>&1; then
  echo 'Plaintext remote bind accepted without opt-in' >&2; exit 1
fi
for ENCODER in turbojpeg auto h264_nvenc h264_qsv h264_amf h264_vaapi h264_videotoolbox; do
  env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --encoder "$ENCODER" --session-policy strict >/dev/null
done
for BAD in '--encoder invalid' '--session-policy invalid' '--bitrate-kbps 127' '--bitrate-kbps 100001'; do
  if env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" $BAD >/dev/null 2>&1; then
    echo "Invalid v9 option accepted: $BAD" >&2; exit 1
  fi
done
echo 'OK: v9 encoder/session/TLS policy argument regressions'

OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_server_options" --encoder=h264_nvenc --bitrate-kbps=4096 --session-policy=backend)
printf '%s\n' "$OUTPUT" | grep -q '^ENCODER=h264_nvenc$'
printf '%s\n' "$OUTPUT" | grep -q '^BITRATE=4096$'
printf '%s\n' "$OUTPUT" | grep -q '^SESSIONPOLICY=backend$'
OUTPUT=$(env LAZDESK_TOKEN="$TOKEN" "$TMP/test_client_options" --keyboard=remote --no-h264 --allow-insecure)
printf '%s\n' "$OUTPUT" | grep -q '^KEYBOARD=remote$'
printf '%s\n' "$OUTPUT" | grep -q '^H264=0$'
printf '%s\n' "$OUTPUT" | grep -q '^ALLOWINSECURE=1$'
echo 'OK: v9 option values, keyboard mode, codec capability and transport opt-in'
