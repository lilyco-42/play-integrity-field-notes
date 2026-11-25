#!/bin/sh
# pi-remote.sh -- host-side wrapper: connect, push, run.
#
#   sh scripts/pi-remote.sh doctor                 # read-only health check
#   sh scripts/pi-remote.sh fix vending-sdk off    # reversible fix
#   sh scripts/pi-remote.sh fix target
#   sh scripts/pi-remote.sh discover               # find the phone's real IP:port (adb mdns lies)
#   sh scripts/pi-remote.sh push-file local.txt /data/local/tmp/remote.txt
#
# Why a wrapper: a plain
#   adb shell 'su -c "grep -E '^(id|name)=' /data/adb/modules/x/module.prop"'
# blows up with "sh: syntax error: unexpected '('" -- the device shell eats the quotes.
# Every command here is therefore pushed to /data/local/tmp and executed as one bare path.
#
# Env:
#   SERIAL=<ip:port|serial>   target device; default = whatever adb has
#   ADB=<path to adb>         default: adb
#   KEEP=1                    keep the pushed temp file

set -u

ADB="${ADB:-adb}"
SERIAL="${SERIAL:-}"
say() { echo "[pi-remote] $*"; }
die() { echo "[pi-remote] error: $*" >&2; exit 1; }

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

adb_() {
  if [ -n "$SERIAL" ]; then "$ADB" -s "$SERIAL" "$@"; else "$ADB" "$@"; fi
}

connect() {
  # Every adb invocation gets its own connection attempt: the wireless daemon drops
  # the session between calls, and "device not found" is the normal failure mode.
  [ -n "$SERIAL" ] || return 0
  case "$SERIAL" in
    *:*) "$ADB" connect "$SERIAL" >/dev/null 2>&1 || say "connect returned non-zero, trying anyway" ;;
  esac
  n="$("$ADB" devices 2>/dev/null | grep -c 'device$')"
  [ "$n" -gt 1 ] && say "warning: $n devices attached; -s $SERIAL is doing the disambiguation"
  return 0
}

discover() {
  # avahi sees the real mDNS record; "adb mdns services" is often empty on a
  # multi-homed host (enp1s0 + wlan0 + docker0 + waydroid0) -- that is not a phone bug.
  if command -v avahi-browse >/dev/null 2>&1; then
    echo "--- avahi-browse (authoritative) ---"
    avahi-browse -rtp _adb-tls-connect._tcp 2>/dev/null \
      | awk -F';' '/^=/ {printf "%s:%s\t%s\n", $8, $9, $4}'
  fi
  echo "--- adb mdns services (may be empty) ---"
  "$ADB" mdns services 2>/dev/null || true
}

push_file() { # push_file <local> [remote]
  l="${1:-}"; r="${2:-/data/local/tmp/$(basename "$l")}"
  [ -f "$l" ] || die "no such file: $l"
  adb_ push "$l" "$r" >/dev/null || die "adb push failed"
  echo "$r"
}

run_root() { # run_root <local script> [args...]
  s="${1:-}"; shift || true
  [ -f "$s" ] || die "no such script: $s"
  remote_path="/data/local/tmp/pi-$$-$(basename "$s")"
  adb_ push "$s" "$remote_path" >/dev/null || die "adb push failed"
  args=""
  for a in "$@"; do args="$args $a"; done
  # exactly one level of quoting left: su -c "sh <path> <args>"
  adb_ shell "su -c \"sh $remote_path$args\""
  rc=$?
  [ "${KEEP:-}" = "1" ] || adb_ shell "su -c \"rm -f $remote_path\"" >/dev/null 2>&1
  return $rc
}

case "${1:-}" in
  doctor)   shift; connect; run_root "$HERE/pi-doctor.sh" "$@" ;;
  fix)      shift; connect; run_root "$HERE/pi-fix.sh" "$@" ;;
  discover) discover ;;
  push-file) shift; push_file "$@" ;;
  *)
    echo "usage: $0 doctor | fix vending-sdk <on|off> | fix target | discover | push-file <local> [remote]" >&2
    exit 1 ;;
esac
