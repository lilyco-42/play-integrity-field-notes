#!/system/bin/sh
# pi-fix.sh -- two reversible fixes for a Play Integrity / TrickyStore setup.
#
#   pi-fix.sh vending-sdk <on|off>   flip spoofVendingSdk in pif.json (backup, restart, verify)
#   pi-fix.sh target                 repair target.txt (stop the cron that owns it, re-add '!' targets)
#
# Run on the phone as root:
#   adb push scripts/pi-fix.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/pi-fix.sh vending-sdk off"
#
# From the host:
#   sh scripts/pi-remote.sh fix vending-sdk off
#
# It force-stops com.android.vending and com.google.android.gms (that is how PIF re-injects).
# It NEVER reboots the phone. Every change is preceded by a timestamped backup, and the
# exact rollback command is printed on the way out.
#
# Extra env:
#   PI_ROOT=<dir>   relocate the /data/adb prefix (used by the offline test suite)
#   PI_YES=1        skip the confirmation prompt (non-interactive use)
#   PI_NO_SLEEP=1   skip the settle waits (tests only)
#
# Exit codes: 0 ok, 1 error, 2 refused (no confirmation)

set -u

D="${PI_ROOT:-}/data/adb"
STAMP="$(date +%Y%m%d-%H%M%S)"
NOSLEEP="${PI_NO_SLEEP:-}"

say()  { echo "[pi-fix] $*"; }
die()  { echo "[pi-fix] error: $*" >&2; exit 1; }
confirm() {
  [ "${PI_YES:-}" = "1" ] && return 0
  printf '[pi-fix] %s -- continue? [y/N] ' "$1" >&2
  read -r a || a=n
  case "$a" in y|Y|yes|YES) return 0 ;; *) say "aborted"; exit 2 ;; esac
}
sleep_long() { [ -n "$NOSLEEP" ] && return 0; sleep "$1"; }

json_ok() {  # json_ok <file> -> 0 if parseable (python3 optional, best effort)
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" 2>/dev/null
}

# replace the value of a top-level boolean key in a JSON file, or append it if absent
# set_bool <file> <key> <true|false>
set_bool() {
  f="$1"; k="$2"; v="$3"
  [ -f "$f" ] || { say "skip: $f not found"; return 0; }
  n="$(grep -n "\"$k\"" "$f" 2>/dev/null | head -n1 | cut -d: -f1)"
  if [ -n "$n" ]; then
    sed -i "${n}s/\"$k\"[[:space:]]*:[[:space:]]*[a-zA-Z]*/\"$k\": $v/" "$f" \
      || die "sed failed on $f line $n"
  else
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$f" "$k" "$v" <<'PY' || die "python insert failed on $f"
import json, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3].lower() == "true"
d = json.load(open(path, encoding="utf-8"))
d[key] = val
with open(path, "w", encoding="utf-8") as fh:
    json.dump(d, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    else
      last="$(grep -n '}' "$f" | tail -n1 | cut -d: -f1)"
      [ -n "$last" ] || die "cannot find a closing brace in $f"
      sed -i "${last}s/}/  \"$k\": $v,\n}/" "$f" || die "sed insert failed on $f"
    fi
  fi
  grep -n "\"$k\"" "$f" | head -n2
}

cmd_vending_sdk() {
  case "${1:-}" in
    on|true|1)   VAL=true ;;
    off|false|0) VAL=false ;;
    *) die "usage: pi-fix.sh vending-sdk <on|off>" ;;
  esac

  LIVE="$D/pif.json"
  MOD="$D/modules/playintegrityfix/pif.json"
  [ -f "$LIVE" ] || die "$LIVE not found -- is PlayIntegrityFix installed?"

  confirm "set spoofVendingSdk=$VAL in $LIVE (force-stops Play Store + GMS, no reboot)"

  cp -f "$LIVE" "$LIVE.bak-$STAMP" || die "backup failed"
  say "backup -> $LIVE.bak-$STAMP"
  if [ -f "$MOD" ]; then
    cp -f "$MOD" "$MOD.bak-$STAMP" && say "backup -> $MOD.bak-$STAMP"
  else
    say "warn: $MOD missing, only the live config is touched"
  fi

  say "== editing =="
  set_bool "$LIVE" spoofVendingSdk "$VAL"
  [ -f "$MOD" ] && set_bool "$MOD" spoofVendingSdk "$VAL"

  json_ok "$LIVE" || die "JSON became invalid -- roll back: cp $LIVE.bak-$STAMP $LIVE"

  say "== restarting vending + gms so the injected PIF re-reads the config =="
  command -v logcat >/dev/null 2>&1 && logcat -c 2>/dev/null
  command -v am >/dev/null 2>&1 && am force-stop com.android.vending 2>/dev/null
  command -v am >/dev/null 2>&1 && am force-stop com.google.android.gms 2>/dev/null
  sleep_long 2
  if command -v am >/dev/null 2>&1; then
    am start -n com.android.vending/com.google.android.finsky.activities.MainActivity >/dev/null 2>&1 \
      && say "Play Store launched" || say "could not launch Play Store (not installed?)"
  fi

  sleep_long 8
  say "== verify =="
  if command -v pidof >/dev/null 2>&1; then
    p="$(pidof com.android.vending 2>/dev/null)"
    if [ -n "$p" ]; then say "vending alive, pid=$p"; else say "vending NOT running"; fi
  fi
  if command -v logcat >/dev/null 2>&1; then
    n="$(logcat -d -b crash 2>/dev/null | grep -c com.android.vending || true)"
    say "crash-buffer lines mentioning vending: ${n:-0}"
    case "${n:-0}" in
      ''|*[!0-9]*) ;;
      0) say "no new crash recorded -- good" ;;
      *) say "still crashing:"; logcat -d -b crash 2>/dev/null | grep com.android.vending | tail -n3 ;;
    esac
  fi
  say "rollback: cp $LIVE.bak-$STAMP $LIVE"
}

cmd_target() {
  T="$D/tricky_store/target.txt"
  [ -f "$T" ] || die "$T not found -- is TrickyStore installed?"

  confirm "rewrite $T and stop the cron that overwrites it"

  say "== 1. stop the overwriter =="
  TAL="$D/modules/TEE_AutoList"
  if [ -d "$TAL" ]; then
    [ -e "$TAL/disable" ] || { touch "$TAL/disable" && say "marked $TAL disabled (undo: rm $TAL/disable)"; }
    if command -v ps >/dev/null 2>&1; then
      for pid in $(ps -A -o PID,ARGS 2>/dev/null | grep -i '[c]ron' | awk '{print $1}'); do
        kill "$pid" 2>/dev/null && say "killed cron pid $pid"
      done
    fi
  else
    say "TEE_AutoList not installed here, skipping"
  fi

  cp -f "$T" "$T.bak-$STAMP" || die "backup failed"
  say "backup -> $T.bak-$STAMP"

  say "== 2. force the bang targets =="
  for PKG in \
    com.google.android.gms.unstable \
    com.android.vending \
    com.google.android.apps.walletnfcrel \
    com.google.android.gms \
    com.google.android.gsf \
    io.github.vvb2060.keyattestation
  do
    grep -vxF "$PKG" "$T" > "$T.tmp" 2>/dev/null && mv "$T.tmp" "$T"
    grep -qxF "$PKG!" "$T" || echo "$PKG!" >> "$T"
  done
  grep -n '!$' "$T" || say "warn: no '!' targets after the rewrite"

  say "== 3. wait >60s to prove nothing rewrites it any more =="
  m1="$(stat -c %Y "$T" 2>/dev/null || echo 0)"
  sleep_long 70
  m2="$(stat -c %Y "$T" 2>/dev/null || echo 0)"
  if [ "$m1" = "$m2" ]; then
    say "mtime unchanged -- the overwriter is gone"
  else
    say "WARN: mtime still moving ($m1 -> $m2); another cron owns the file:"
    ps -A -o PID,ARGS 2>/dev/null | grep -i '[c]ron'
  fi

  say "== 4. make sure the daemon is alive =="
  if command -v pidof >/dev/null 2>&1 && pidof TrickyStore >/dev/null 2>&1; then
    say "daemon already running (pid $(pidof TrickyStore))"
  else
    say "daemon down, starting the module service script"
    ( cd "$D/tricky_store/.." 2>/dev/null || cd /; sh "$D/modules/tricky_store/service.sh" >/dev/null 2>&1 & )
    sleep_long 3
    if command -v pidof >/dev/null 2>&1 && pidof TrickyStore >/dev/null 2>&1; then
      say "started (pid $(pidof TrickyStore))"
    else
      say "still down -- a reboot is needed; that decision is yours, this script will not reboot"
    fi
  fi

  say "rollback: cp $T.bak-$STAMP $T"
}

case "${1:-}" in
  vending-sdk) shift; cmd_vending_sdk "${1:-}" ;;
  target)      cmd_target ;;
  *) echo "usage: $0 vending-sdk <on|off> | $0 target" >&2; exit 1 ;;
esac
