#!/usr/bin/env python3
"""Hermetic tests for icloud-photos-export.py. A fake `osxphotos` (query --print/--count, export with a JSON report)
reads a library description from $FAKE_LIB; a fake `hl` maps `homelab:<path>` onto a tmpdir. No Photos, no network.
Run: python3 scripts/icloud-photos-export.test.py"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icloud-photos-export.py")

FAKE_OSXPHOTOS = r'''#!/usr/bin/env python3
import json, os, shutil, sys
lib = json.load(open(os.environ["FAKE_LIB"]))
a = sys.argv[1:]
def arg(flag):
    return a[a.index(flag) + 1]
if a[0] == "query" and "--count" in a:
    print("Processing keywords.")
    print(lib["shared"])
elif a[0] == "query":
    print("Processing photo details.")
    n = lambda v: "_" if v in (None, False) else str(v)
    for x in lib["assets"]:
        d = lib["dir"]
        files = x["files"]
        p = os.path.join(d, files[0]) if x["local"] else None
        ed = os.path.join(d, files[1]) if x.get("edited") and x["local"] else None
        lv = os.path.join(d, x["live"]) if x.get("live") and x.get("live_local", x["local"]) else None
        edflag = True if x.get("edited") else None
        print("|".join([x["uuid"], n(x.get("mod")), x["added"], n(edflag), str(x["size"]), n(p), n(ed), n(lv),
                        n(True if x.get("live") else None), x["date"]]))
elif a[0] == "export":
    stage = os.path.realpath(a[1])
    uuids = open(arg("--uuid-from-file")).read().split()
    rows = []
    for x in lib["assets"]:
        if x["uuid"] not in uuids:
            continue
        ym = x["date"][:4] + "/" + x["date"][5:7]
        stamp = x["date"][:10] + "_" + x["date"][11:19].replace(":", "")
        names = [stamp + "_" + x["orig"]]
        if x.get("edited"):
            names.append(stamp + "_" + os.path.splitext(x["orig"])[0] + "_edited.jpeg")
        if x.get("live"):
            names.append(stamp + "_" + os.path.splitext(x["orig"])[0] + ".mov")
        for name in names:
            fn = os.path.join(stage, ym, name)
            if x.get("error"):
                rows.append({"filename": fn, "exported": False, "missing": False, "error": "boom", "uuid": x["uuid"]})
                continue
            if not x.get("live_local", x["local"]) and name.endswith(".mov"):
                rows.append({"filename": fn, "exported": False, "missing": True, "error": "", "uuid": x["uuid"]})
                continue
            os.makedirs(os.path.dirname(fn), exist_ok=True)
            open(fn, "w").write("data-" + x["uuid"] + "-" + str(x.get("mod")))
            rows.append({"filename": fn, "exported": True, "missing": False, "error": "", "uuid": x["uuid"]})
    open(os.path.join(stage, ".osxphotos_export.db"), "w").write("x")
    json.dump(rows, open(arg("--report"), "w"))
    print("Processed")
'''

FAKE_HL = r'''#!/usr/bin/env python3
import os, shutil, sys
root = os.environ["FAKE_HOMELAB"]
a = sys.argv[1:]
def real(p):
    return os.path.join(root, p.split(":", 1)[1]) if p.startswith("homelab:") else p
open(os.path.join(root, "calls.log"), "a").write(" ".join(a[:1]) + "\n")
if a[0] == "lsd":
    if os.environ.get("FAKE_HL_DOWN"):
        sys.stderr.write("dial tcp: i/o timeout\n"); sys.exit(1)
    if os.environ.get("FAKE_HL_SECRET"):
        sys.stderr.write("hl: could not resolve op://homelab/s3-agent\n"); sys.exit(1)
    sys.exit(0)
if a[0] == "copy":
    src, dst = a[1], real(a[2])
    for d, _, fs in os.walk(src):
        for f in fs:
            t = os.path.join(dst, os.path.relpath(os.path.join(d, f), src))
            os.makedirs(os.path.dirname(t), exist_ok=True)
            shutil.copyfile(os.path.join(d, f), t)
    sys.exit(0)
if a[0] == "check":
    src, dst = a[1], real(a[2])
    for d, _, fs in os.walk(src):
        for f in fs:
            t = os.path.join(dst, os.path.relpath(os.path.join(d, f), src))
            if not os.path.exists(t) or os.path.getsize(t) != os.path.getsize(os.path.join(d, f)):
                sys.exit(1)
    sys.exit(0)
if a[0] == "copyto":
    src, dst = real(a[1]), real(a[2])
    if not os.path.exists(src):
        sys.exit(1)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    sys.exit(0)
sys.exit(2)
'''


def asset(uuid, day, orig, **kw):
    a = {"uuid": uuid, "date": f"{day}T10:20:30+01:00", "added": f"{day}T11:00:00+01:00", "orig": orig,
         "files": [f"originals/{uuid}.heic", f"resources/{uuid}_edit.jpeg"], "size": 1000, "local": True, "mod": None}
    a.update(kw)
    return a


class Export(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(dir=os.path.realpath(tempfile.gettempdir()))
        self.lib_dir = os.path.join(self.tmp, "lib")
        os.makedirs(os.path.join(self.lib_dir, "originals"))
        os.makedirs(os.path.join(self.lib_dir, "resources"))
        self.home = os.path.join(self.tmp, "homelab")
        os.makedirs(self.home)
        self.state = os.path.join(self.tmp, "state")
        for name, body in (("osxphotos", FAKE_OSXPHOTOS), ("hl", FAKE_HL)):
            p = os.path.join(self.tmp, name)
            open(p, "w").write(body)
            os.chmod(p, 0o755)
        self.assets = []
        self.shared = 7
        self.env_extra = {}

    def lib(self, assets=None):
        for x in (assets if assets is not None else self.assets):
            for f in x["files"] + ([x["live"]] if x.get("live") else []):
                if x["local"] or f == x.get("live"):
                    open(os.path.join(self.lib_dir, f), "w").write("x")
        json.dump({"dir": self.lib_dir, "shared": self.shared, "assets": assets if assets is not None else self.assets},
                  open(os.path.join(self.tmp, "lib.json"), "w"))

    def run_job(self, *args, **env):
        e = dict(os.environ, FAKE_LIB=os.path.join(self.tmp, "lib.json"), FAKE_HOMELAB=self.home,
                 ICLOUD_EXPORT_RUNNER="direct", ICLOUD_EXPORT_STATE=self.state, ICLOUD_EXPORT_LIBRARY=self.lib_dir,
                 OSXPHOTOS_BIN=os.path.join(self.tmp, "osxphotos"), HL_BIN=os.path.join(self.tmp, "hl"),
                 ICLOUD_EXPORT_MIN_FREE_GIB="0")
        e.update(self.env_extra)
        e.update(env)
        return subprocess.run([sys.executable, SCRIPT, *args], env=e, capture_output=True, text=True)

    def share(self, *parts):
        return os.path.join(self.home, "ssd/Bilder/iCloud", *parts)

    def status(self):
        return json.load(open(self.share(".status.json")))

    def test_first_run_second_run_changes_and_removals(self):
        self.assets = [
            asset("A1", "2021-03-04", "IMG_0001.HEIC", edited=True),
            asset("B2", "2024-05-30", "IMG_0043.HEIC", live="resources/B2.mov"),
            asset("C3", "2025-07-22", "IMG_3878.JPG"),
            asset("D4", "2026-11-01", "IMG_9999.HEIC", local=False),
        ]
        self.lib()
        r = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.exists(self.share("2021/03/2021-03-04_102030_IMG_0001.HEIC")))
        self.assertTrue(os.path.exists(self.share("2021/03/2021-03-04_102030_IMG_0001_edited.jpeg")))
        self.assertTrue(os.path.exists(self.share("2024/05/2024-05-30_102030_IMG_0043.HEIC")))
        self.assertTrue(os.path.exists(self.share("2024/05/2024-05-30_102030_IMG_0043.mov")))
        self.assertFalse(os.path.exists(self.share(".osxphotos_export.db")))
        s = self.status()
        self.assertEqual((s["library_assets"], s["exported_assets"], s["pending_local"], s["new_this_run"], s["failed"]),
                         (4, 3, 1, 3, 0))
        self.assertEqual(s["shared_album_assets_excluded"], 7)
        self.assertTrue(s["last_ok"])
        self.assertTrue(os.path.exists(self.share(".ledger.json")))
        self.assertFalse(os.path.exists(os.path.join(self.state, "stage")))

        # second run: nothing unchanged is exported again
        r = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("0 to export", r.stdout)
        self.assertEqual(self.status()["new_this_run"], 0)

        # the original of D4 arrives (Photos finished downloading): exported on the next run
        self.assets[3]["local"] = True
        self.lib()
        r = self.run_job()
        self.assertEqual(self.status()["new_this_run"], 1)
        self.assertEqual(self.status()["pending_local"], 0)
        self.assertTrue(os.path.exists(self.share("2026/11/2026-11-01_102030_IMG_9999.HEIC")))

        # an edit changes the stamp: that asset is re-exported, the others are not
        self.assets[2]["mod"] = "2026-11-15T01:00:00+01:00"
        self.lib()
        r = self.run_job()
        self.assertIn("1 to export (1 changed)", r.stdout)
        self.assertEqual(self.status()["changed_this_run"], 1)
        self.assertEqual(open(self.share("2025/07/2025-07-22_102030_IMG_3878.JPG")).read(), "data-C3-2026-11-15T01:00:00+01:00")

        # an asset removed from Photos stays in the archive and in the counts
        self.lib(self.assets[:3])
        r = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.status()["kept_after_removal"], 1)
        self.assertTrue(os.path.exists(self.share("2026/11/2026-11-01_102030_IMG_9999.HEIC")))

    def test_live_photo_waits_for_its_video(self):
        self.assets = [asset("B2", "2024-05-30", "IMG_0043.HEIC", live="resources/B2.mov", live_local=False)]
        self.lib()
        r = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        s = self.status()
        self.assertEqual((s["exported_assets"], s["pending_local"]), (0, 1))
        self.assertFalse(os.path.exists(self.share("2024/05/2024-05-30_102030_IMG_0043.HEIC")))

    def test_batches(self):
        self.assets = [asset(f"U{i}", f"2022-01-{i + 1:02d}", f"IMG_{i}.HEIC", files=[f"originals/U{i}.heic"]) for i in range(5)]
        self.lib()
        r = self.run_job(ICLOUD_EXPORT_MAX_ASSETS="2")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.count("batch:"), 3)
        self.assertEqual(self.status()["exported_assets"], 5)

    def test_one_failed_asset_fails_the_run_but_uploads_the_rest(self):
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"]),
                       asset("B2", "2021-03-05", "IMG_2.HEIC", files=["originals/B2.heic"], error=True)]
        self.lib()
        r = self.run_job()
        self.assertEqual(r.returncode, 1)
        s = self.status()
        self.assertEqual((s["exported_assets"], s["failed"]), (1, 1))
        self.assertTrue(os.path.exists(self.share("2021/03/2021-03-04_102030_IMG_1.HEIC")))
        self.assertFalse(os.path.exists(self.share("2021/03/2021-03-05_102030_IMG_2.HEIC")))
        self.assertIsNone(s["last_ok"])

    def test_name_collision_never_overwrites(self):
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"])]
        self.lib()
        self.assertEqual(self.run_job().returncode, 0)
        # another asset that would land on the same archive name
        self.assets = [self.assets[0], asset("Z9", "2021-03-04", "IMG_1.HEIC", files=["originals/Z9.heic"])]
        self.lib()
        r = self.run_job()
        self.assertEqual(r.returncode, 1)
        self.assertIn("name collision", r.stdout)
        self.assertEqual(open(self.share("2021/03/2021-03-04_102030_IMG_1.HEIC")).read(), "data-A1-None")

    def hc_stubs(self, core_up_rc):
        """A fake `hc` that logs its call and runs what follows `exec --timeout N`, and a stub core-up.sh."""
        hc = os.path.join(self.tmp, "hc")
        open(hc, "w").write('#!/bin/sh\necho "$@" >> "$FAKE_HOMELAB/hc.log"\n[ "$1" = exec ] || exit 9\nshift 3\nexec "$@"\n')
        os.chmod(hc, 0o755)
        up = os.path.join(self.tmp, "core-up.sh")
        open(up, "w").write(f"echo core is down. Fix: start it\nexit {core_up_rc}\n")
        return dict(ICLOUD_EXPORT_RUNNER="hc", HC_BIN=hc, ICLOUD_EXPORT_CORE_UP=up)

    def test_core_down_fails_without_calling_hc(self):
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"])]
        self.lib()
        r = self.run_job(**self.hc_stubs(1))
        self.assertEqual(r.returncode, 1)
        self.assertIn("herdr core is not up", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.home, "hc.log")))  # hc would start a stray core

    def test_through_the_core(self):
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"])]
        self.lib()
        r = self.run_job(**self.hc_stubs(0))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.status()["exported_assets"], 1)
        self.assertIn("exec --timeout 600 /bin/sh -c", open(os.path.join(self.home, "hc.log")).read())

    def test_homelab_away_is_a_skip(self):
        self.lib()
        r = self.run_job(FAKE_HL_DOWN="1")
        self.assertEqual(r.returncode, 0)
        self.assertIn("skipped: HomeLab not reachable", r.stdout)

    def test_missing_secret_is_a_failure(self):
        self.lib()
        r = self.run_job(FAKE_HL_SECRET="1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("cannot authenticate", r.stdout)

    def test_low_free_space_refuses(self):
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"])]
        self.lib()
        r = self.run_job(ICLOUD_EXPORT_MIN_FREE_GIB="99999999")
        self.assertEqual(r.returncode, 1)
        self.assertIn("below the", r.stdout)
        self.assertFalse(os.path.exists(self.share("2021")))

    def test_lost_state_restores_the_ledger_from_the_share(self):
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"])]
        self.lib()
        self.assertEqual(self.run_job().returncode, 0)
        os.remove(os.path.join(self.state, "ledger.json"))
        r = self.run_job()
        self.assertIn("0 to export", r.stdout)

    def test_empty_query_with_a_ledger_refuses(self):
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"])]
        self.lib()
        self.assertEqual(self.run_job().returncode, 0)
        self.lib([])
        r = self.run_job()
        self.assertEqual(r.returncode, 1)
        self.assertIn("returned no assets", r.stdout)

    def test_status_flag(self):
        self.assertEqual(self.run_job("--status").returncode, 1)
        self.assets = [asset("A1", "2021-03-04", "IMG_1.HEIC", files=["originals/A1.heic"])]
        self.lib()
        self.run_job()
        r = self.run_job("--status")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout)["exported_assets"], 1)


if __name__ == "__main__":
    unittest.main()
