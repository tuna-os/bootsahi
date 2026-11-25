#!/usr/bin/env python3
"""Verify a screenshot capture receipt written by ScreenshotCaptureTests.

Usage: verify-capture-receipt.py DIR [--source-sha SHA] [--run-id ID]
                                     [--run-attempt N]

Fails (exit 1) unless DIR holds a receipt that this run produced, in state
"complete", covering every expected fixture and the walkthrough GIF, with
hashes matching the files on disk. A skipped XCTest, a partial capture, stale
committed images or a stale receipt all fail here; existence of PNGs is never
enough. The scope is synthetic AppKit rendering only: interaction, backend
intent and real installation must be "not-run".
"""
import argparse, hashlib, json, os, struct, sys

SCHEMA = "bootsahi.capture-receipt/1"
FIXTURES = ["01-welcome", "02-choose-image", "03-settings",
            "04-disk-space", "05-installing", "06-recoveryos"]
NOT_RUN = ["interaction", "backend_intent", "real_installation"]
IDENTITY = ["source_sha", "run_id", "run_attempt", "binary_sha256",
            "macos", "xcode", "renderer", "theme", "scale"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", head[16:24])


def verify(d, source_sha="", run_id="", run_attempt=""):
    errs = []
    rp = os.path.join(d, "capture-receipt.json")
    if not os.path.isfile(rp):
        return ["no capture-receipt.json (capture skipped or never ran)"]
    try:
        with open(rp) as f:
            r = json.load(f)
    except ValueError as e:
        return [f"receipt is not valid JSON: {e}"]
    if r.get("schema") != SCHEMA:
        errs.append(f"schema {r.get('schema')!r} != {SCHEMA!r}")
    if r.get("state") != "complete":
        errs.append(f"state is {r.get('state')!r}: {r.get('failure', '')}")
    if r.get("scope") != "synthetic-appkit-render":
        errs.append("scope must be synthetic-appkit-render")
    caps = r.get("capabilities", {})
    if caps.get("render_fixture") != "run":
        errs.append("capabilities.render_fixture must be 'run'")
    for k in NOT_RUN:
        if caps.get(k) != "not-run":
            errs.append(f"capabilities.{k} must be 'not-run', got {caps.get(k)!r}")
    ident = r.get("identity", {})
    for k in IDENTITY:
        if ident.get(k) in (None, ""):
            errs.append(f"identity.{k} missing")
    for k, want in (("source_sha", source_sha), ("run_id", run_id),
                    ("run_attempt", run_attempt)):
        if want and ident.get(k) != want:
            errs.append(f"stale receipt: identity.{k} {ident.get(k)!r} != {want!r}")
    fx = {e.get("id"): e for e in r.get("fixtures", [])}
    for fid in FIXTURES + ["walkthrough"]:
        e = fx.get(fid)
        if e is None:
            errs.append(f"fixture {fid} not in receipt")
            continue
        path = os.path.join(d, e.get("file", ""))
        want_file = fid + (".gif" if fid == "walkthrough" else ".png")
        if e.get("file") != want_file:
            errs.append(f"{fid}: file {e.get('file')!r} != {want_file!r}")
            continue
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            errs.append(f"{fid}: file missing or empty")
            continue
        if sha256(path) != e.get("sha256"):
            errs.append(f"{fid}: sha256 mismatch")
        if fid != "walkthrough":
            size = png_size(path)
            if size is None:
                errs.append(f"{fid}: not a PNG")
            elif size != (e.get("width"), e.get("height")):
                errs.append(f"{fid}: dimensions {size} != receipt")
        else:
            with open(path, "rb") as g:
                if not g.read(6).startswith(b"GIF8"):
                    errs.append("walkthrough: not a GIF")
        if e.get("audit", {}).get("violations") != []:
            errs.append(f"{fid}: audit violations {e.get('audit', {}).get('violations')!r}")
        if fid != "walkthrough" and not all(
                k in e.get("audit", {}) for k in ("placeholder", "ink", "action_bar")):
            errs.append(f"{fid}: audit results missing")
    for fid in fx:
        if fid not in FIXTURES + ["walkthrough"]:
            errs.append(f"unexpected fixture id {fid!r}")
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--source-sha", default="")
    ap.add_argument("--run-id", default="")
    ap.add_argument("--run-attempt", default="")
    a = ap.parse_args()
    errs = verify(a.dir, a.source_sha, a.run_id, a.run_attempt)
    for e in errs:
        print(f"::error::capture receipt: {e}")
    if errs:
        return 1
    print("capture receipt OK: 6 fixtures + walkthrough, synthetic render scope")
    return 0


if __name__ == "__main__":
    sys.exit(main())
