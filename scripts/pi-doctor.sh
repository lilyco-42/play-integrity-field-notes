#!/system/bin/sh
# pi-doctor.sh -- Play Integrity / KernelSU read-only health check.
#
# READ-ONLY by design: never writes a file, never starts/stops an app, never reboots.
# Safe to run on a production phone.
#
# On the phone (as root):
#   adb push scripts/pi-doctor.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/pi-doctor.sh"
#
# From the host, use the wrapper:
#   sh scripts/pi-remote.sh doctor
#
# Offline testing uses PI_ROOT to relocate /data/adb, and PI_NO_SLEEP=1 to skip waits:
#   PI_ROOT=tests/fixtures/root PI_NO_SLEEP=1 PATH=tests/fixtures/bin:$PATH sh scripts/pi-doctor.sh
#
# Exit code: 0 = no FAIL, 1 = at least one FAIL.

set -u

D="${PI_ROOT:-}/data/adb"
LIVE="$D/pif.json"
MOD="$D/modules/playintegrityfix/pif.json"
TS="$D/tricky_store"
MODS="$D/modules"
MU="$D/modules_update"
PROC="${PI_PROC:-/proc}"   # overridable so the offline suite can fake /proc/<pid>/maps

WARN=0
FAIL=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; WARN=1; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
hdr()  { echo; echo "=== $* ==="; }
have() { command -v "$1" >/dev/null 2>&1; }
num()  { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

hdr "0. environment"
SDK="$(getprop ro.build.version.sdk 2>/dev/null || true)"
SDK="$(num "$SDK")"
echo "  device : $(getprop ro.product.model 2>/dev/null || true) ($(getprop ro.product.device 2>/dev/null || true))"
echo "  android: $(getprop ro.build.version.release 2>/dev/null || true) (API $SDK)"
echo "  kernel : $(uname -r 2>/dev/null || true)"
echo "  uid    : $(id 2>/dev/null || true)"
echo "  adb    : $D"
if [ "$SDK" -ge 34 ]; then
  ok "Android 14+ -- registerReceiver() enforces RECEIVER_EXPORTED, so spoofVendingSdk=true is dangerous"
elif [ "$SDK" -gt 0 ]; then
  ok "Android < 14 -- the RECEIVER_EXPORTED crash class does not apply"
else
  warn "cannot read ro.build.version.sdk"
fi

hdr "1. KernelSU / root"
if have ksud; then
  ok "ksud: $(ksud -V 2>/dev/null | head -n1)"
elif [ -d "$D/ksu" ] || [ -d "$D/apatch" ]; then
  warn "root-manager data dir exists but ksud is not in PATH"
else
  warn "no ksud and no /data/adb/ksu -- is this a KernelSU device?"
fi
CTX="$(id 2>/dev/null | sed -n 's/.*context=//p')"
echo "  SELinux context: ${CTX:-unknown}"
case "$CTX" in
  *ksu*) ok "root domain is u:r:ksu:s0" ;;
  *)     warn "context is not ksu-flavoured -- KernelSU modules may behave differently" ;;
esac

hdr "2. Play Store (com.android.vending)"
if have pidof && pidof com.android.vending >/dev/null 2>&1; then
  ok "vending running (pid $(pidof com.android.vending))"
else
  warn "vending not running (often harmless: the app is simply closed)"
fi
VCRASH=0
if have logcat; then
  VCRASH="$(num "$(logcat -d -b crash 2>/dev/null | grep -c com.android.vending || true)")"
fi
echo "  crash-buffer lines mentioning vending: $VCRASH"
if [ "$VCRASH" -gt 0 ]; then
  LAST="$(logcat -d -b crash 2>/dev/null | grep com.android.vending | tail -n1)"
  echo "  last: $LAST"
  case "$LAST" in
    *RECEIVER_EXPORTED*|*RECEIVER_NOT_EXPORTED*)
      bad "RECEIVER_EXPORTED SecurityException -> set spoofVendingSdk=false in $LIVE (docs/01, docs/02)" ;;
    *) warn "other crash present -- read the stack trace by hand" ;;
  esac
fi

hdr "3. PIF config (the live file and the module copy are NOT the same thing)"
SV=""
if [ -f "$LIVE" ]; then
  ok "live config present: $LIVE"
  SV="$(grep -o 'spoofVendingSdk[^,}]*' "$LIVE" 2>/dev/null | grep -o 'true\|false' | head -n1)"
  echo "  live spoofVendingSdk = ${SV:-<absent>}"
  if [ "$SV" = "true" ] && [ "$SDK" -ge 34 ]; then
    bad "spoofVendingSdk=true on Android 14+ crashes the Play Store (docs/01)"
  fi
else
  bad "missing $LIVE -- is PlayIntegrityFix installed?"
fi
if [ -f "$MOD" ]; then
  MV="$(grep -o 'spoofVendingSdk[^,}]*' "$MOD" 2>/dev/null | grep -o 'true\|false' | head -n1)"
  echo "  module-copy spoofVendingSdk = ${MV:-<absent>}"
  if [ -f "$LIVE" ]; then
    if cmp -s "$LIVE" "$MOD"; then
      ok "live and module copies are byte-identical"
    else
      warn "the two pif.json differ -- only the live one is read by the injected .so (docs/02)"
    fi
  fi
else
  warn "no module copy at $MOD"
fi
SO="$D/modules/playintegrityfix/inject/arm64-v8a.so"
if [ -f "$SO" ] && have strings; then
  echo "  pif path hard-coded in the .so: $(strings "$SO" 2>/dev/null | grep -m1 pif.json)"
fi

hdr "4. TrickyStore"
if [ -d "$TS" ]; then ok "module data dir present"; else bad "no $TS"; fi
TEEBROKEN=0
if [ -f "$TS/tee_status" ]; then
  TEE="$(tr -d ' \n' < "$TS/tee_status" 2>/dev/null)"
  echo "  tee_status: $TEE"
  case "$TEE" in *true*) TEEBROKEN=1 ;; esac
else
  warn "no tee_status"
fi
if [ -f "$TS/target.txt" ]; then
  LINES="$(num "$(wc -l < "$TS/target.txt" 2>/dev/null)")"
  BANGS="$(num "$(grep -c '!$' "$TS/target.txt" 2>/dev/null || true)")"
  echo "  target.txt: $LINES lines, $BANGS forced (bang) targets"
  if [ "$TEEBROKEN" = "1" ] && [ "$BANGS" -eq 0 ]; then
    bad "teeBroken=true but no '!'-suffixed targets -> Play Integrity is guaranteed red (docs/03)"
  fi
  M1="$(stat -c %Y "$TS/target.txt" 2>/dev/null || echo 0)"
  if [ "${PI_NO_SLEEP:-}" = "" ]; then sleep 3; fi
  M2="$(stat -c %Y "$TS/target.txt" 2>/dev/null || echo 0)"
  if [ "$M1" != "$M2" ]; then
    bad "target.txt is being rewritten right now -> a cron job owns it (docs/03)"
    if have ps; then
      echo "  candidates:"
      ps -A -o PID,ARGS 2>/dev/null | grep -i '[c]ron' | sed 's/^/    /'
    fi
  else
    ok "target.txt mtime is stable"
  fi
else
  bad "missing $TS/target.txt"
fi
if have pidof && pidof TrickyStore >/dev/null 2>&1; then
  ok "daemon running (pid $(pidof TrickyStore))"
else
  warn "daemon not running"
fi
KS="$(pidof keystore2 2>/dev/null | cut -d' ' -f1)"
if [ -n "${KS:-}" ] && [ -r "$PROC/$KS/maps" ]; then
  HOOK="$(num "$(grep -c tricky "$PROC/$KS/maps" 2>/dev/null || true)")"
  if [ "$HOOK" -gt 0 ]; then
    ok "libtricky_store.so is mapped into keystore2 ($HOOK segments) -- hook active"
  else
    bad "keystore2 has no libtricky_store.so mapping -- hook not installed"
  fi
else
  warn "keystore2 pid unknown -- cannot verify the hook"
fi
if have logcat; then
  echo "  recent TS errors: $(num "$(logcat -d 2>/dev/null | grep -c -i -E 'verify1 failed|unverified!|Bad file descriptor' || true)")"
fi

hdr "5. keybox"
if [ -f "$TS/keybox.xml" ]; then
  CN="$(num "$(grep -c '<Certificate' "$TS/keybox.xml" 2>/dev/null || true)")"
  ok "keybox.xml present, $CN certificates (expiry: scripts/keybox-check.py)"
else
  warn "no keybox.xml -- TrickyStore falls back to the real (broken) TEE"
fi

hdr "6. Zygisk provider"
if have ps; then
  if ps -A -o ARGS 2>/dev/null | grep -q '[z]ygisk-ptrace'; then
    ok "a Zygisk implementation is injecting (zygisk-ptrace)"
  else
    warn "no zygisk-ptrace process -- Zygisk-based modules are inert"
  fi
  COMP="$(num "$(ps -A -o ARGS 2>/dev/null | grep -c '[c]ompanion' || true)")"
  echo "  companion processes: $COMP"
  if [ "$COMP" -eq 0 ]; then
    warn "no companions -- PlayIntegrityFix / Shamiko cannot hook anything"
  fi
fi
if [ -e "$MODS/zygisksu/disable" ] && [ ! -e "$MODS/rezygisk/disable" ]; then
  ok "zygisksu disabled while rezygisk is enabled (correct: they are mutually exclusive)"
fi

hdr "7. installed modules"
if [ -d "$MODS" ]; then
  for m in "$MODS/"*/; do
    [ -d "$m" ] || continue
    i="$(basename "$m")"
    d=enabled; [ -e "${m}disable" ] && d=DISABLED
    rm_=""; [ -e "${m}remove" ] && rm_=" [remove pending]"
    v="$(grep -m1 '^version=' "${m}module.prop" 2>/dev/null | cut -d= -f2-)"
    printf '  %-22s %-9s %s%s\n' "$i" "$d" "$v" "$rm_"
  done
else
  bad "no $MODS"
fi

hdr "8. pending module updates"
PEND="$(ls -A "$MU" 2>/dev/null | tr '\n' ' ')"
if [ -n "$PEND" ]; then
  warn "modules_update is not empty -> a reboot is required: $PEND"
else
  ok "nothing pending"
fi

hdr "summary"
echo "  FAIL=$FAIL  WARN=$WARN"
if [ "$FAIL" = "1" ]; then
  echo "  -> real problems above; fix them in the order the README recommends"
  exit 1
fi
if [ "$WARN" = "1" ]; then
  echo "  -> warnings only, nothing fatal"
  exit 0
fi
echo "  -> all good"
exit 0
