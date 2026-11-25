#!/usr/bin/env python3
"""Positive and negative controls for verify-capture-receipt.py."""
import hashlib, importlib.util, json, os, shutil, struct, tempfile, unittest, zlib

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("v", os.path.join(here, "verify-capture-receipt.py"))
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)

SHA, RUN, ATT = "a" * 40, "123", "1"


def png(w=4, h=3):
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + b"\x80\x80\x80" * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def make(d):
    fx = []
    for fid in v.FIXTURES:
        data = png(); open(os.path.join(d, fid + ".png"), "wb").write(data)
        fx.append({"id": fid, "file": fid + ".png", "sha256": hashlib.sha256(data).hexdigest(),
                   "width": 4, "height": 3, "fixture_state": "x",
                   "audit": {"placeholder": 0, "ink": 0.1, "action_bar": 0.1, "violations": []}})
    gif = b"GIF89a" + b"\0" * 10
    open(os.path.join(d, "walkthrough.gif"), "wb").write(gif)
    fx.append({"id": "walkthrough", "file": "walkthrough.gif",
               "sha256": hashlib.sha256(gif).hexdigest(), "width": 4, "height": 3,
               "fixture_state": "x", "audit": {"violations": []}})
    r = {"schema": v.SCHEMA, "harness_version": 1, "state": "complete", "failure": "",
         "scope": "synthetic-appkit-render",
         "capabilities": {"render_fixture": "run", "interaction": "not-run",
                          "backend_intent": "not-run", "real_installation": "not-run"},
         "identity": {"source_sha": SHA, "run_id": RUN, "run_attempt": ATT, "binary_sha256": "b",
                      "macos": "15", "xcode": "16", "renderer": "r", "theme": "aqua", "scale": 2},
         "fixtures": fx}
    save(d, r)
    return r


def save(d, r):
    json.dump(r, open(os.path.join(d, "capture-receipt.json"), "w"))


class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(); self.addCleanup(shutil.rmtree, self.d)
        self.r = make(self.d)

    def check(self, **kw):
        return v.verify(self.d, SHA, RUN, ATT, **kw)

    def mutate(self, fn):
        fn(self.r); save(self.d, self.r)

    def test_positive(self):
        self.assertEqual(self.check(), [])

    def test_skipped_capture_no_receipt(self):
        os.remove(os.path.join(self.d, "capture-receipt.json"))
        self.assertTrue(self.check())

    def test_stale_committed_images_only(self):
        os.remove(os.path.join(self.d, "capture-receipt.json"))
        self.assertTrue(any("no capture-receipt" in e for e in self.check()))

    def test_failed_or_partial_state(self):
        self.mutate(lambda r: r.update(state="failed", failure="boom"))
        self.assertTrue(self.check())

    def test_partial_fixture_list(self):
        self.mutate(lambda r: r["fixtures"].pop(2))
        self.assertTrue(any("03-settings" in e for e in self.check()))

    def test_stale_source_identity(self):
        self.mutate(lambda r: r["identity"].update(source_sha="c" * 40))
        self.assertTrue(any("stale" in e for e in self.check()))

    def test_stale_run_id(self):
        self.mutate(lambda r: r["identity"].update(run_id="1"))
        self.assertTrue(any("run_id" in e for e in self.check()))

    def test_wrong_fixture_id(self):
        self.mutate(lambda r: r["fixtures"][0].update(id="01-bogus"))
        self.assertTrue(self.check())

    def test_missing_file(self):
        os.remove(os.path.join(self.d, "02-choose-image.png"))
        self.assertTrue(any("missing" in e for e in self.check()))

    def test_empty_file(self):
        open(os.path.join(self.d, "01-welcome.png"), "wb").close()
        self.assertTrue(self.check())

    def test_hash_mismatch(self):
        open(os.path.join(self.d, "walkthrough.gif"), "ab").write(b"x")
        self.assertTrue(any("sha256" in e for e in self.check()))

    def test_audit_violation_fails(self):
        self.mutate(lambda r: r["fixtures"][1]["audit"].update(violations=["action-bar"]))
        self.assertTrue(any("audit" in e for e in self.check()))

    def test_install_claim_rejected(self):
        self.mutate(lambda r: r["capabilities"].update(real_installation="run"))
        self.assertTrue(any("real_installation" in e for e in self.check()))


if __name__ == "__main__":
    unittest.main()
