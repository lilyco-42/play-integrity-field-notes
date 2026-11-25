#!/usr/bin/env python3
"""keybox-check.py -- is the keybox actually the reason Play Integrity is red?

Pulls the certificates out of a TrickyStore keybox.xml and asks openssl for their
validity window, so "my keybox expired" stops being a guess.

    python3 scripts/keybox-check.py /data/adb/tricky_store/keybox.xml
    adb pull /data/adb/tricky_store/keybox.xml /tmp/kb.xml
    python3 scripts/keybox-check.py /tmp/kb.xml

Exit code: 0 = every certificate is currently valid, 1 = something is expired or
unreadable, 2 = usage error.

Why bother: in the case this repo documents, all 6 certificates were valid until
2034/2042 -- the red verdict came from teeBroken=true plus a cron-rewritten
target.txt, not from the keybox. Checking this first saves a wasted keybox hunt.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import os

CERT_RE = re.compile(r"<Certificate[^>]*>(.*?)</Certificate>", re.S)
PEM_RE = re.compile(
    r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", re.S
)


def extract_pem(xml: str) -> list[str]:
    """keybox.xml embeds base64 DER inside <Certificate>; some exports are already PEM."""
    pems: list[str] = []
    for block in CERT_RE.findall(xml):
        if "-----BEGIN" in block:
            pems.extend(PEM_RE.findall(block))
            continue
        body = "".join(block.split())
        if not body:
            continue
        lines = "\n".join(body[i : i + 64] for i in range(0, len(body), 64))
        pems.append(
            "-----BEGIN CERTIFICATE-----\n" + lines + "\n-----END CERTIFICATE-----\n"
        )
    if not pems:  # the whole file may already be PEM
        pems = PEM_RE.findall(xml)
    return pems


def inspect(pem: str, openssl: str) -> tuple[dict, bool, str]:
    """Return (fields, is_expired, error).

    Everything goes through a real temp file: openssl 4.x dropped "-in -", so
    piping the PEM to stdin silently fails and every cert would look expired.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem)
        path = fh.name
    try:
        out = subprocess.run(
            [openssl, "x509", "-noout", "-subject", "-dates", "-in", path],
            capture_output=True,
            text=True,
        )
        if out.returncode != 0:
            return {}, False, (out.stderr.strip() or "openssl x509 failed")
        fields = {}
        for line in out.stdout.splitlines():
            if "=" in line:
                key, val = line.split("=", 1)
                fields[key.strip()] = val.strip()
        chk = subprocess.run(
            [openssl, "x509", "-noout", "-checkend", "0", "-in", path],
            capture_output=True,
            text=True,
        )
        return fields, chk.returncode != 0, ""
    finally:
        os.unlink(path)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="validate the certificates inside a TrickyStore keybox.xml"
    )
    ap.add_argument("keybox", help="path to keybox.xml")
    ap.add_argument("--openssl", default="openssl", help="openssl binary (default: openssl)")
    a = ap.parse_args()

    if not shutil.which(a.openssl):
        print("error: " + a.openssl + " not found -- install openssl", file=sys.stderr)
        return 2
    try:
        xml = open(a.keybox, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("error: cannot read " + a.keybox + ": " + str(e), file=sys.stderr)
        return 2

    pems = extract_pem(xml)
    if not pems:
        print(
            "error: no <Certificate> blocks found -- is this really a keybox.xml?",
            file=sys.stderr,
        )
        return 2

    bad = 0
    print(str(len(pems)) + " certificate(s) in " + a.keybox)
    print()
    for i, pem in enumerate(pems, 1):
        fields, is_expired, err = inspect(pem, a.openssl)
        if err:
            print("[" + str(i) + "] [FAIL] unreadable: " + err)
            bad += 1
            continue
        print("[" + str(i) + "] " + fields.get("subject", "?"))
        print(
            "     valid "
            + fields.get("notBefore", "?")
            + " -> "
            + fields.get("notAfter", "?")
        )
        if is_expired:
            print("     [FAIL] expired")
            bad += 1

    print()
    if bad:
        print(str(bad) + " certificate(s) failed -- a keybox problem is plausible this time")
        return 1
    print("all certificates currently valid -- if Play Integrity is still red, look at")
    print("tee_status (teeBroken) and target.txt's '!' suffixes instead (docs/03).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
