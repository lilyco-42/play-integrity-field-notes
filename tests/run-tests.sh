#!/bin/sh
# run-tests.sh -- offline test suite. No phone, no root, no network.
#
# Every test runs scripts/*.sh against a fixture tree (tests/fixtures/root-*) with
# stub commands (tests/fixtures/bin) standing in for getprop/pidof/logcat/ps/id/ksud.
# This is how the scripts stay honest: the assertions test the real logic, not a mock of it.
#
#   sh tests/run-tests.sh            # run everything
#   sh tests/run-tests.sh -v         # also dump the script output of failing cases
#
# Exit code: 0 all passed, 1 something failed.

set -u

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$(CDPATH= cd -- "$HERE/.." && pwd)"
FIX="$HERE/fixtures"
# $REPO/scripts in the git repo, $REPO/artifacts inside an unpacked .mpkg
SCRIPTS="${PI_SCRIPTS:-}"
if [ -z "$SCRIPTS" ]; then
  if [ -f "$REPO/scripts/pi-doctor.sh" ]; then SCRIPTS="$REPO/scripts"; else SCRIPTS="$REPO/artifacts"; fi
fi
VERBOSE=${1:-}

PASS=0
FAILN=0
FAILED=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
flop() {
  FAILN=$((FAILN + 1)); FAILED="$FAILED
 - $1"; printf '  FAIL %s\n' "$1"
  [ -n "$VERBOSE" ] && { printf '       %s\n' "$2"; echo '-------- output --------'; echo "$3"; echo '------------------------'; }
}
# assert_eq <name> <want> <got> [output]
assert_eq() { [ "$2" = "$3" ] && pass "$1" || flop "$1 (want '$2' got '$3')" "$3" "${4:-}"; }
# assert_in <name> <needle> <haystack> [output]
assert_in() { printf '%s' "$3" | grep -qF -- "$2" && pass "$1" || flop "$1 (missing: $2)" "$3" "${4:-}"; }
# assert_not_in <name> <needle> <haystack> [output]
assert_not_in() { printf '%s' "$3" | grep -qF -- "$2" && flop "$1 (unwanted: $2)" "$3" "${4:-}" || pass "$1"; }

# run a script with the fixture environment; stdout+stderr -> $TMP/out, exit code -> $TMP/rc
run() { # run <root> <script> [args...]
  root="$1"; shift
  PATH="$FIX/bin:$PATH" \
  PI_ROOT="$root" \
  PI_FIXTURE_PROPS="${PI_FIXTURE_PROPS:-$FIX/props-android16.txt}" \
  PI_FIXTURE_LOG="${PI_FIXTURE_LOG:-$FIX/logcat-clean.txt}" \
  PI_FIXTURE_PS="${PI_FIXTURE_PS:-$FIX/ps-clean.txt}" \
  PI_FIXTURE_PIDS="${PI_FIXTURE_PIDS-com.android.vending TrickyStore keystore2}" \
  PI_YES="${PI_YES-1}" \
  PI_NO_SLEEP=1 \
  PI_PROC="${PI_PROC:-$root/proc}" \
  sh "$@" >"$TMP/out" 2>&1 <"/dev/null"
  echo $? >"$TMP/rc"
}
OUT() { cat "$TMP/out"; }
RC()  { cat "$TMP/rc"; }

# a throwaway copy of a fixture root
copyroot() { # copyroot <src> -> echoes path
  d="$(mktemp -d "$TMP/r.XXXXXX")"
  cp -a "$1/." "$d/"
  echo "$d"
}

printf 'fixtures/bin: %s\n' "$(ls "$FIX/bin" | tr '\n' ' ')"
echo

# ─────────────────────────────────────────────────────────────── syntax first
echo '[syntax]'
for s in "$SCRIPTS"/*.sh; do
  if sh -n "$s" 2>"$TMP/e"; then pass "sh -n $(basename "$s")"; else flop "sh -n $(basename "$s")" "$(cat "$TMP/e")" ""; fi
done

# ─────────────────────────────────────────────────────────────── 1. healthy device
echo
echo '[doctor: healthy device]'
run "$FIX/root-good" "$SCRIPTS/pi-doctor.sh"
O="$(OUT)"
assert_eq   'exit 0 on healthy device' 0 "$(RC)"
assert_in   'reports 8 sections'      '=== 8.' "$O"
assert_in   'live config found'       'live config present' "$O"
assert_in   'bang targets counted'    'forced (bang) targets' "$O"
assert_in   'all good'                'all good' "$O"
assert_not_in 'no FAIL lines'         '[FAIL]' "$O"
assert_in   'hard-coded .so path found' '/pif.json' "$O"
assert_in   'mutually exclusive pair detected' 'mutually exclusive' "$O"
assert_in   'keystore2 hook verified'  'libtricky_store.so is mapped into keystore2' "$O"

# ─────────────────────────────────────────────────────────────── 2. read-only proof
echo
echo '[doctor: is genuinely read-only]'
R="$(copyroot "$FIX/root-good")"
BEFORE="$(cd "$R" && find . -type f -exec sha256sum {} \; | sort)"
run "$R" "$SCRIPTS/pi-doctor.sh"
AFTER="$(cd "$R" && find . -type f -exec sha256sum {} \; | sort)"
if [ "$BEFORE" = "$AFTER" ]; then pass 'no file in the tree changed'; else flop 'doctor modified the fixture tree' "$BEFORE" "$AFTER"; fi

# ─────────────────────────────────────────────────────────────── 3. broken device
echo
echo '[doctor: the real broken device]'
run "$FIX/root-broken" "$SCRIPTS/pi-doctor.sh"
O="$(OUT)"
assert_eq 'exit 1 when things are broken' 1 "$(RC)"
assert_in 'flags spoofVendingSdk=true'    'spoofVendingSdk=true on Android 14+' "$O"
assert_in 'flags missing bang targets'    "teeBroken=true but no" "$O"
assert_in 'flags the two pif.json differing' 'only the live one is read' "$O"

echo
echo '[doctor: same broken device but Android 13]'
run "$FIX/root-broken" "$SCRIPTS/pi-doctor.sh"
O="$(OUT)"
PI_FIXTURE_PROPS="$FIX/props-android13.txt" run "$FIX/root-broken" "$SCRIPTS/pi-doctor.sh"
O13="$(OUT)"
assert_not_in 'spoofVendingSdk is not blamed on Android 13' 'spoofVendingSdk=true on Android 14+' "$O13"
assert_in   'Android 13 branch reported' 'Android < 14' "$O13"

echo
echo '[doctor: cron detected via mtime]'
# simulate an overwriter: a background loop that touches target.txt while the doctor looks
R="$(copyroot "$FIX/root-good")"
( i=0; while [ $i -lt 40 ]; do touch "$R/data/adb/tricky_store/target.txt"; sleep 0.4; i=$((i+1)); done ) &
LOOP=$!
PATH="$FIX/bin:$PATH" PI_ROOT="$R" PI_FIXTURE_PROPS="$FIX/props-android16.txt" \
PI_FIXTURE_LOG="$FIX/logcat-clean.txt" PI_FIXTURE_PS="$FIX/ps-cron.txt" PI_PROC="$R/proc" \
sh "$SCRIPTS/pi-doctor.sh" >"$TMP/out" 2>&1
kill $LOOP 2>/dev/null
wait $LOOP 2>/dev/null
O="$(OUT)"
assert_in 'detects the live overwriter' 'is being rewritten right now' "$O"
assert_in 'lists the cron process' '/data/adb/modules/TEE_AutoList/cron/root' "$O"

# ─────────────────────────────────────────────────────────────── 4. vending-sdk fix
echo
echo '[fix: vending-sdk off]'
R="$(copyroot "$FIX/root-broken")"
run "$R" "$SCRIPTS/pi-fix.sh" vending-sdk off
O="$(OUT)"
assert_eq 'exit 0' 0 "$(RC)"
LIVE="$R/data/adb/pif.json"
MOD="$R/data/adb/modules/playintegrityfix/pif.json"
assert_in 'live file set to false' '"spoofVendingSdk": false' "$(cat "$LIVE")"
assert_in 'module copy set to false too' '"spoofVendingSdk": false' "$(cat "$MOD")"
if ls "$R"/data/adb/pif.json.bak-* >/dev/null 2>&1; then pass 'live backup created'; else flop 'no live backup' '' ''; fi
if ls "$R"/data/adb/modules/playintegrityfix/pif.json.bak-* >/dev/null 2>&1; then pass 'module backup created'; else flop 'no module backup' '' ''; fi
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$LIVE" 2>/dev/null; then pass 'live JSON still parses'; else flop 'live JSON broken' '' "$(cat "$LIVE")"; fi
assert_in 'prints the rollback command' 'rollback: cp' "$O"
assert_in 'restarted vending' 'Play Store launched' "$O"

echo
echo '[fix: vending-sdk on]'
run "$R" "$SCRIPTS/pi-fix.sh" vending-sdk on
assert_eq 'exit 0' 0 "$(RC)"
assert_in 'back to true' '"spoofVendingSdk": true' "$(cat "$LIVE")"
run "$R" "$SCRIPTS/pi-fix.sh" vending-sdk bogus
assert_eq 'rejects a bogus argument' 1 "$(RC)"

echo
echo '[fix: inserts the key when it is absent]'
R="$(copyroot "$FIX/root-nokey")"
run "$R" "$SCRIPTS/pi-fix.sh" vending-sdk off
O="$(OUT)"
assert_eq 'exit 0' 0 "$(RC)"
assert_in 'key was inserted' '"spoofVendingSdk": false' "$(cat "$R/data/adb/pif.json")"
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$R/data/adb/pif.json" 2>/dev/null; then pass 'JSON valid after insert'; else flop 'JSON broken after insert' '' "$(cat "$R/data/adb/pif.json")"; fi

echo
echo '[fix: refuses without confirmation]'
R="$(copyroot "$FIX/root-good")"
BEFORE="$(sha256sum "$R/data/adb/pif.json")"
printf 'n\n' | PATH="$FIX/bin:$PATH" PI_ROOT="$R" PI_NO_SLEEP=1 \
  sh "$SCRIPTS/pi-fix.sh" vending-sdk off >"$TMP/out" 2>&1
echo $? >"$TMP/rc"
assert_eq 'exit 2 when declined' 2 "$(RC)"
assert_eq 'file untouched when declined' "$BEFORE" "$(sha256sum "$R/data/adb/pif.json")"

# ─────────────────────────────────────────────────────────────── 5. target repair
echo
echo '[fix: target]'
R="$(copyroot "$FIX/root-broken")"
PI_FIXTURE_PS="$FIX/ps-cron.txt" run "$R" "$SCRIPTS/pi-fix.sh" target
O="$(OUT)"
T="$R/data/adb/tricky_store/target.txt"
assert_eq 'exit 0' 0 "$(RC)"
assert_eq 'six bang targets present' 6 "$(grep -c '!$' "$T")"
for P in com.google.android.gms.unstable com.android.vending com.google.android.apps.walletnfcrel com.google.android.gms com.google.android.gsf io.github.vvb2060.keyattestation; do
  assert_in "target has ${P}!" "${P}!" "$(cat "$T")"
done
assert_eq 'no duplicate plain entry' 0 "$(grep -cxF com.android.vending "$T")"
if [ -e "$R/data/adb/modules/TEE_AutoList/disable" ]; then pass 'TEE_AutoList marked disabled'; else flop 'TEE_AutoList not disabled' '' ''; fi
if ls "$T".bak-* >/dev/null 2>&1; then pass 'target.txt backup created'; else flop 'no target.txt backup' '' ''; fi
assert_in 'mtime stability reported' 'mtime unchanged' "$O"
assert_in 'prints the rollback command' 'rollback: cp' "$O"
run "$R" "$SCRIPTS/pi-fix.sh" target
assert_eq 'idempotent: still six bang targets' 6 "$(grep -c '!$' "$T")"

# ─────────────────────────────────────────────────────────────── 6. no-phone guard
echo
echo '[fix: refuses on a device without the files]'
E="$(mktemp -d "$TMP/e.XXXXXX")"
run "$E" "$SCRIPTS/pi-fix.sh" vending-sdk off
assert_eq 'exit 1 when pif.json is missing' 1 "$(RC)"
assert_in 'says what is missing' 'not found' "$(OUT)"

# ─────────────────────────────────────────────────────────────── 7. keybox checker
echo
echo '[keybox-check.py]'
KB="$TMP/kb"; mkdir -p "$KB"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KB/k.pem" -out "$KB/c.pem" \
  -days 3650 -subj "/CN=test-keybox" >/dev/null 2>&1
B64="$(grep -v -- '-----' "$KB/c.pem" | tr -d '\n')"
printf '<Keybox>\n<Certificate>\n%s\n</Certificate>\n</Keybox>\n' "$B64" > "$KB/good.xml"
python3 "$SCRIPTS/keybox-check.py" "$KB/good.xml" >"$TMP/out" 2>&1
echo $? >"$TMP/rc"
assert_eq  'exit 0 for a valid keybox' 0 "$(RC)"
assert_in  'reports the certificate count' '1 certificate(s)' "$(OUT)"
assert_in  'prints the validity window' 'valid' "$(OUT)"
assert_in  'says the keybox is not the problem' 'all certificates currently valid' "$(OUT)"

printf '<Keybox>\n<Certificate>\nnot-a-certificate\n</Certificate>\n</Keybox>\n' > "$KB/bad.xml"
python3 "$SCRIPTS/keybox-check.py" "$KB/bad.xml" >"$TMP/out" 2>&1
echo $? >"$TMP/rc"
assert_eq  'exit 1 when a certificate is unreadable' 1 "$(RC)"
assert_in  'flags the unreadable certificate' '[FAIL] unreadable' "$(OUT)"

printf '<Keybox></Keybox>\n' > "$KB/empty.xml"
python3 "$SCRIPTS/keybox-check.py" "$KB/empty.xml" >"$TMP/out" 2>&1
echo $? >"$TMP/rc"
assert_eq  'exit 2 when there is nothing to check' 2 "$(RC)"

# ─────────────────────────────────────────────────────────────── 8. host wrapper
echo
echo '[pi-remote.sh]'
LOG="$TMP/adb.log"; : > "$LOG"; SROOT="$TMP/phone"; mkdir -p "$SROOT/data/local/tmp"
ADB_LOG="$LOG" ADB_STUB_ROOT="$SROOT" SERIAL=192.168.10.127:44125 KEEP=1 \
  PATH="$FIX/bin:$PATH" PI_ROOT="$FIX/root-good" PI_PROC="$FIX/root-good/proc" PI_NO_SLEEP=1 \
  PI_FIXTURE_PROPS="$FIX/props-android16.txt" PI_FIXTURE_LOG="$FIX/logcat-clean.txt" \
  PI_FIXTURE_PS="$FIX/ps-clean.txt" PI_FIXTURE_PIDS="com.android.vending TrickyStore keystore2" \
  sh "$SCRIPTS/pi-remote.sh" doctor >"$TMP/out" 2>&1 <"/dev/null"
echo $? >"$TMP/rc"
assert_eq  'propagates the doctor exit code' 0 "$(RC)"
assert_in  'the remote run really produced a report' 'all good' "$(OUT)"
assert_in  'connects to the wireless address first' 'adb connect 192.168.10.127:44125' "$(cat "$LOG")"
assert_in  'pins every call with -s' 'adb -s 192.168.10.127:44125 push' "$(cat "$LOG")"
assert_in  'pushes instead of inlining a quoted command' 'pi-doctor.sh' "$(cat "$LOG")"
assert_in  'executes it through su -c' 'su -c "sh /data/local/tmp/' "$(cat "$LOG")"

LOG="$TMP/adb2.log"; : > "$LOG"
ADB_LOG="$LOG" ADB_STUB_ROOT="$SROOT" PATH="$FIX/bin:$PATH" sh "$SCRIPTS/pi-remote.sh" fix vending-sdk off >"$TMP/out" 2>&1 <"/dev/null"
echo $? >"$TMP/rc"
assert_in  'cleans up the pushed file afterwards' 'rm -f /data/local/tmp/' "$(cat "$LOG")"

ADB_LOG="$TMP/adb3.log" ADB_STUB_ROOT="$SROOT" PATH="$FIX/bin:$PATH" sh "$SCRIPTS/pi-remote.sh" bogus >"$TMP/out" 2>&1
echo $? >"$TMP/rc"
assert_eq  'exit 1 on an unknown subcommand' 1 "$(RC)"
assert_in  'prints usage' 'usage:' "$(OUT)"

LOG="$TMP/adb4.log"; : > "$LOG"
ADB_LOG="$LOG" ADB_STUB_ROOT="$SROOT" PATH="$FIX/bin:$PATH" sh "$SCRIPTS/pi-remote.sh" discover >"$TMP/out" 2>&1
assert_in  'discover mentions adb mdns' 'adb mdns services' "$(cat "$LOG")"
assert_in  'discover explains the empty list is normal' 'may be empty' "$(OUT)"

# ─────────────────────────────────────────────────────────────── summary
echo
echo '──────────────────────────────────────────────'
printf 'passed %d, failed %d\n' "$PASS" "$FAILN"
if [ "$FAILN" -gt 0 ]; then
  echo "failed:"
  printf '%s\n' "$FAILED"
  exit 1
fi
echo 'all tests passed'
exit 0
