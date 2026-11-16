#!/usr/bin/env python3
"""Hermetic tests for ext-mirror.py. The real volume gate runs against a stub `diskutil` and a temp directory as the
volume; the HomeLab is a temp directory behind a fake `hl` that is real rclone with an `alias` remote (so sync,
--backup-dir, filters and check --download behave as they do against S3). No disk, share or network is touched.
Needs rclone and macOS's plutil (the gate); without them the suite says so and passes.
Run: python3 scripts/ext-mirror.test.py"""
import datetime
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "ext-mirror.py")
TODAY = datetime.date.today().isoformat()

FAKE_HL = r"""#!/bin/bash
[ -f "$FAKE_HL_DENIED" ] && { echo "operation error S3: ListObjects, https response error StatusCode: 403, AccessDenied" >&2; exit 1; }
export RCLONE_CONFIG=
export RCLONE_CONFIG_HOMELAB_TYPE=alias
export RCLONE_CONFIG_HOMELAB_REMOTE="$FAKE_HOMELAB"
[ -f "$FAKE_HL_DOWN" ] && { echo "dial tcp: lookup s3.example.com: no such host" >&2; exit 1; }
[ -f "$FAKE_HL_NOSECRET" ] && { echo "hl: could not resolve op://homelab/s3-agent/ACCESS_KEY_ID" >&2; exit 1; }
exec rclone "$@"
"""

FAKE_DISKUTIL = r"""#!/bin/bash
mode=$(/bin/cat "$FAKE_MODE")
case "$mode" in
  absent) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Error</key><true/></dict></plist>'; exit 1 ;;
  locked) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>DeviceIdentifier</key><string>disk99s1</string><key>FileVault</key><true/><key>Locked</key><true/><key>MountPoint</key><string></string></dict></plist>' ;;
  *) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>DeviceIdentifier</key><string>disk99s1</string><key>FileVault</key><true/><key>Locked</key><false/><key>MountPoint</key><string>%s</string></dict></plist>' "$FAKE_VOLUME" ;;
esac
"""


def write(path, text="x", mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mtime:
        os.utime(path, (mtime, mtime))


def tree(root):
    out = {}
    for d, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root)] = open(p).read()
    return out


@unittest.skipUnless(shutil.which("rclone") and os.path.exists("/usr/bin/plutil"), "needs rclone and macOS plutil")
class ExtMirror(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="ext-mirror-test.")
        t = self.t
        self.home = os.path.join(t, "home")          # the "internal disk": must stay empty
        self.vol = os.path.join(t, "vol", "EXT")     # the stand-in mount point
        self.lab = os.path.join(t, "lab")            # the HomeLab
        for d in (self.home, os.path.join(t, "bin"), self.lab):
            os.makedirs(d)
        os.makedirs(self.vol)
        write(os.path.join(self.vol, ".volume-gate"), "marker")
        self.mode = os.path.join(t, "mode")
        write(self.mode, "present")
        for name, body in (("hl", FAKE_HL), ("diskutil", FAKE_DISKUTIL)):
            p = os.path.join(t, "bin", name)
            write(p, body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        self.cfg = os.path.join(t, "external-volume.json")
        write(self.cfg, json.dumps({"name": "EXT", "sentinel": ".volume-gate", "attached": True}))
        self.env = dict(
            os.environ, HOME=self.home, HL_BIN=os.path.join(t, "bin", "hl"), FAKE_HOMELAB=self.lab,
            FAKE_HL_DOWN=os.path.join(t, "hl-down"), FAKE_HL_NOSECRET=os.path.join(t, "hl-nosecret"), FAKE_HL_DENIED=os.path.join(t, "hl-denied"),
            VOLUME_GATE_CONFIG=self.cfg, VOLUME_GATE_DISKUTIL=os.path.join(t, "bin", "diskutil"),
            FAKE_MODE=self.mode, FAKE_VOLUME=self.vol, EXT_MIRROR_MIN_FREE_GIB="0")
        write(os.path.join(self.lab, "ssd", "Dokumente", "tax.txt"), "tax 2025")
        write(os.path.join(self.lab, "ssd", "Bilder", "a.jpg"), "photo")
        write(os.path.join(self.lab, "hdd", "fuji", "RAWs", "x.RAF"), "raw-x")
        write(os.path.join(self.lab, "hdd", "fuji", "Videos", "v.MOV"), "video-v")
        write(os.path.join(self.lab, "hdd", "Videos", "Projekte", "p.mp4"), "project")
        self.mirror = os.path.join(self.vol, "mirror")

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def run_job(self, *args, **env):
        p = subprocess.run([sys.executable, SCRIPT, *args], env=dict(self.env, **env), capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr

    def status(self):
        with open(os.path.join(self.mirror, ".status.json")) as f:
            return json.load(f)

    def test_first_run_mirrors_all_three_sources_and_writes_status(self):
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        self.assertEqual(tree(os.path.join(self.mirror, "ssd")), tree(os.path.join(self.lab, "ssd")))
        self.assertEqual(tree(os.path.join(self.mirror, "fuji")), tree(os.path.join(self.lab, "hdd", "fuji")))
        self.assertEqual(tree(os.path.join(self.mirror, "videos")), tree(os.path.join(self.lab, "hdd", "Videos")))
        s = self.status()
        self.assertTrue(s["ok"])
        self.assertTrue(s["started"].endswith("Z") and s["finished"].endswith("Z"))
        self.assertEqual(s["sources"]["ssd"]["files"], 2)
        self.assertEqual(s["sources"]["fuji"]["files"], 2)
        self.assertEqual(s["sources"]["videos"]["files"], 1)
        self.assertEqual(s["sources"]["ssd"]["transferred"], 2)
        self.assertEqual(s["sources"]["ssd"]["errors"], 0)
        self.assertEqual(s["sources"]["ssd"]["bytes"], len("tax 2025") + len("photo"))
        self.assertTrue(s["check"]["ok"])
        self.assertGreater(s["check"]["sources"]["ssd"]["sampled"], 0)

    def test_second_run_transfers_nothing_and_skips_the_check(self):
        self.run_job()
        first_check = self.status()["check"]["finished"]
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        s = self.status()
        self.assertEqual(s["sources"]["ssd"]["transferred"], 0)
        self.assertEqual(s["check"]["finished"], first_check)

    def test_what_restic_excludes_is_not_mirrored(self):
        write(os.path.join(self.lab, "ssd", ".sgwtmp", "part"))
        write(os.path.join(self.lab, "ssd", "Dev", "app", "node_modules", "m", "i.js"))
        write(os.path.join(self.lab, "ssd", "Bilder", ".trash", "gone.jpg"))
        write(os.path.join(self.lab, "ssd", "Bilder", "immich", "thumbs", "t.webp"))
        write(os.path.join(self.lab, "ssd", "Bilder", "immich", "upload", "keep.jpg"))
        write(os.path.join(self.lab, "ssd", "Dokumente", ".DS_Store"))
        write(os.path.join(self.lab, "ssd", "Dokumente", "film.tmp"), "a real file")
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        got = tree(os.path.join(self.mirror, "ssd"))
        self.assertEqual(sorted(got), sorted(["Dokumente/tax.txt", "Bilder/a.jpg", "Bilder/immich/upload/keep.jpg", "Dokumente/film.tmp"]))

    def test_a_file_deleted_or_changed_at_the_source_moves_to_deleted(self):
        write(os.path.join(self.lab, "ssd", "test", "gone.txt"), "to be deleted")
        self.run_job()
        os.remove(os.path.join(self.lab, "ssd", "test", "gone.txt"))
        write(os.path.join(self.lab, "ssd", "Dokumente", "tax.txt"), "tax 2026, longer", mtime=1_900_000_000)
        before = tree(self.lab)
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        kept = os.path.join(self.mirror, ".deleted", TODAY, "ssd")
        self.assertEqual(open(os.path.join(kept, "test", "gone.txt")).read(), "to be deleted")
        self.assertEqual(open(os.path.join(kept, "Dokumente", "tax.txt")).read(), "tax 2025")
        self.assertFalse(os.path.exists(os.path.join(self.mirror, "ssd", "test", "gone.txt")))
        self.assertEqual(open(os.path.join(self.mirror, "ssd", "Dokumente", "tax.txt")).read(), "tax 2026, longer")
        self.assertEqual(tree(self.lab), before, "the source of truth is untouched")
        self.assertEqual(self.status()["sources"]["ssd"]["moved_to_deleted"], 2)

    def test_old_deleted_folders_are_removed_and_only_dated_ones(self):
        self.run_job()
        old = (datetime.date.today() - datetime.timedelta(days=31)).isoformat()
        recent = (datetime.date.today() - datetime.timedelta(days=29)).isoformat()
        for d in (old, recent, "not-a-date"):
            write(os.path.join(self.mirror, ".deleted", d, "ssd", "f.txt"))
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        left = sorted(os.listdir(os.path.join(self.mirror, ".deleted")))
        self.assertEqual(left, sorted([recent, "not-a-date"]))

    def test_volume_absent_or_locked_is_one_skipped_line_and_nothing_is_written(self):
        for mode, word in (("absent", "absent"), ("locked", "locked")):
            write(self.mode, mode)
            rc, out = self.run_job()
            self.assertEqual(rc, 3, out)  # a skip is never a green run
            self.assertEqual(out.strip(), f"skipped: volume {word}")
        self.assertEqual(os.listdir(self.home), [], "nothing on the internal disk")
        self.assertFalse(os.path.exists(self.mirror))

    def test_homelab_unreachable_is_skipped_and_not_green(self):
        write(self.env["FAKE_HL_DOWN"], "")
        rc, out = self.run_job()
        self.assertEqual(rc, 3, out)
        self.assertIn("skipped: HomeLab not reachable", out)
        self.assertFalse(os.path.exists(self.mirror), "nothing synced, nothing created")
        self.assertEqual(os.listdir(self.home), [])

    def stamps(self):
        with open(os.path.join(self.home, ".local", "state", "ext-mirror", "last-ok.json")) as f:
            return json.load(f)

    def set_status(self, **fields):
        path = os.path.join(self.mirror, ".status.json")
        s = self.status()
        s.update(fields)
        with open(path, "w") as f:
            json.dump(s, f)

    def hours_ago(self, h):
        return (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_a_clean_run_stamps_every_source_outside_the_volume(self):
        self.run_job()
        got = self.stamps()
        self.assertEqual(sorted(got), ["fuji", "ssd", "videos"])
        self.assertEqual(got["ssd"], self.status()["finished"])

    def test_a_source_that_fails_keeps_its_older_stamp(self):
        self.run_job()
        before = self.stamps()
        old = self.hours_ago(50)
        state = os.path.join(self.home, ".local", "state", "ext-mirror", "last-ok.json")
        with open(state, "w") as f:
            json.dump(dict(before, ssd=old), f)
        shutil.rmtree(os.path.join(self.lab, "ssd"))
        os.makedirs(os.path.join(self.lab, "ssd"))  # the share is not mounted at home: listed empty, refused
        rc, out = self.run_job()
        self.assertEqual(rc, 1, out)
        got = self.stamps()
        self.assertEqual(got["ssd"], old)
        self.assertEqual(got["fuji"], self.status()["finished"])

    def test_if_due_skips_a_recent_clean_run_and_stays_green(self):
        self.run_job()
        self.set_status(finished=self.hours_ago(2))
        rc, out = self.run_job("--if-due")
        self.assertEqual(rc, 0, out)
        self.assertIn("not due", out)
        self.assertNotIn("sync ssd", out)

    def test_a_run_made_before_the_stamps_existed_is_stamped_when_it_is_not_due(self):
        self.run_job()
        shutil.rmtree(os.path.join(self.home, ".local"))
        fin = self.hours_ago(2)
        self.set_status(finished=fin)
        self.run_job("--if-due")
        self.assertEqual(self.stamps(), {"ssd": fin, "fuji": fin, "videos": fin})

    def test_if_due_runs_once_the_last_run_is_old_enough(self):
        self.run_job()
        self.set_status(finished=self.hours_ago(20))
        rc, out = self.run_job("--if-due")
        self.assertEqual(rc, 0, out)
        self.assertIn("sync ssd", out)

    def test_if_due_keeps_a_red_mirror_red_until_the_retry_is_due(self):
        self.run_job()
        self.set_status(ok=False, finished=self.hours_ago(2))
        rc, out = self.run_job("--if-due")
        self.assertEqual(rc, 1, out)
        self.assertIn("not due", out)
        self.set_status(finished=self.hours_ago(7))
        rc, out = self.run_job("--if-due")
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.status()["ok"])

    def test_if_due_with_no_status_runs(self):
        rc, out = self.run_job("--if-due")
        self.assertEqual(rc, 0, out)
        self.assertIn("due: no finished run on record", out)

    def test_a_skipped_night_is_retried_when_the_volume_reads_again(self):
        write(self.mode, "locked")
        rc, _ = self.run_job("--if-due")
        self.assertEqual(rc, 3)
        write(self.mode, "present")
        rc, out = self.run_job("--if-due")
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.status()["ok"])

    def test_a_run_in_progress_makes_the_next_one_skip(self):
        import fcntl
        os.makedirs(self.mirror)
        with open(os.path.join(self.mirror, ".lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        self.assertIn("skipped: a run is already in progress", out)
        self.assertFalse(os.path.exists(os.path.join(self.mirror, "ssd")))
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        self.assertTrue(os.path.exists(os.path.join(self.mirror, "ssd")))

    def test_a_rejected_key_is_a_failure_not_a_skipped_night(self):
        write(self.env["FAKE_HL_DENIED"], "")
        rc, out = self.run_job()
        self.assertEqual(rc, 1, out)
        self.assertIn("FAILED: probe", out)
        self.assertNotIn("skipped", out)

    def test_a_failed_check_is_tried_again_the_next_night(self):
        self.run_job()
        path = os.path.join(self.mirror, "ssd", "Dokumente", "tax.txt")
        st = os.stat(path)
        write(path, "tax 2024")
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
        rc, _ = self.run_job("--check-now")
        self.assertEqual(rc, 1)
        write(path, "tax 2025")  # repaired
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.status()["check"]["ok"])

    def test_a_source_that_fails_to_sync_leaves_the_check_due(self):
        self.run_job()
        first = self.status()["check"]["finished"]
        shutil.rmtree(os.path.join(self.lab, "ssd"))
        os.makedirs(os.path.join(self.lab, "ssd"))  # lists empty over a filled mirror: that source fails
        rc, out = self.run_job("--check-now")
        self.assertEqual(rc, 1, out)
        self.assertIn("sample check incomplete", out)
        self.assertEqual(self.status()["check"]["finished"], first, "the earlier record is kept")

    def test_a_missing_secret_is_a_failure_not_a_skip(self):
        write(self.env["FAKE_HL_NOSECRET"], "")
        rc, out = self.run_job()
        self.assertEqual(rc, 1, out)
        self.assertIn("FAILED: hl cannot resolve its key", out)

    def test_below_the_free_space_floor_it_refuses(self):
        rc, out = self.run_job(EXT_MIRROR_MIN_FREE_GIB="99999999")
        self.assertEqual(rc, 1, out)
        self.assertIn("refusing to start", out)
        self.assertFalse(os.path.exists(self.mirror))

    def test_an_empty_source_over_a_filled_mirror_is_refused_not_mirrored(self):
        self.run_job()
        shutil.rmtree(os.path.join(self.lab, "ssd"))
        os.makedirs(os.path.join(self.lab, "ssd"))
        rc, out = self.run_job()
        self.assertEqual(rc, 1, out)
        self.assertIn("lists empty", out)
        self.assertEqual(open(os.path.join(self.mirror, "ssd", "Dokumente", "tax.txt")).read(), "tax 2025")
        self.assertFalse(self.status()["sources"]["ssd"]["ok"])
        self.assertTrue(self.status()["sources"]["fuji"]["ok"])

    def test_the_sample_check_finds_a_corrupted_mirror_file(self):
        self.run_job()
        path = os.path.join(self.mirror, "ssd", "Dokumente", "tax.txt")
        st = os.stat(path)
        write(path, "tax 2024")  # same size, other bytes
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
        rc, out = self.run_job()
        self.assertEqual(rc, 0, "a normal run compares size and time and sees nothing: " + out)
        rc, out = self.run_job("--check-now")
        self.assertEqual(rc, 1, out)
        c = self.status()["check"]
        self.assertFalse(c["ok"])
        self.assertEqual(c["sources"]["ssd"]["differ"], 1)
        self.assertFalse(self.status()["ok"])

    def test_the_same_seed_draws_the_same_sample(self):
        spec = importlib.util.spec_from_file_location("ext_mirror", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        os.environ["EXT_MIRROR_CHECK_SAMPLE_FILES"] = "5"
        try:
            cfg = mod.Cfg()
        finally:
            del os.environ["EXT_MIRROR_CHECK_SAMPLE_FILES"]
        dest = os.path.join(self.t, "dest")
        for i in range(40):
            write(os.path.join(dest, f"f{i:02}.txt"), f"file {i}")
        flt = os.path.join(self.t, "flt")
        write(flt, mod.FILTERS)
        a, _ = mod.sample_files(cfg, flt, dest, "2026-11-ssd")
        b, _ = mod.sample_files(cfg, flt, dest, "2026-11-ssd")
        c, _ = mod.sample_files(cfg, flt, dest, "2026-12-ssd")
        self.assertEqual(len(a), 5)
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)

    def test_the_sample_is_bounded(self):
        for i in range(30):
            write(os.path.join(self.lab, "ssd", "many", f"f{i:02}.txt"), f"file {i}")
        self.run_job(EXT_MIRROR_CHECK_SAMPLE_FILES="5")
        a = self.status()["check"]["sources"]["ssd"]
        self.assertEqual(a["sampled"], 5)
        self.assertEqual(a["matched"], 5)

    def test_dry_run_writes_nothing(self):
        rc, out = self.run_job("--dry-run")
        self.assertEqual(rc, 0, out)
        self.assertFalse(os.path.exists(os.path.join(self.mirror, ".status.json")))
        self.assertEqual(tree(os.path.join(self.mirror, "ssd")) if os.path.isdir(os.path.join(self.mirror, "ssd")) else {}, {})

    def test_status_prints_the_status_file(self):
        self.run_job()
        rc, out = self.run_job("--status")
        self.assertEqual(rc, 0, out)
        self.assertTrue(json.loads(out)["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
