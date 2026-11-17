#!/usr/bin/env python3
"""ext-mirror — the nightly second local copy of the HomeLab's personal data on the mini's external SSD.

Pulls over S3 (`hl`, the mini's key reads and cannot delete on the HomeLab) behind the volume gate
(scripts/lib/volume-gate.sh): the SSD share, HDD/fuji and HDD/Videos into <volume>/mirror/{ssd,fuji,videos}.

Per run:
  1. The gate: the volume absent, locked or unreadable = one "skipped: volume <state>" line, exit SKIP_RC (3), nothing run or
     created. A skip is not a green run: jobrun grades it failing, and the nightly job's hourly triggers (see --if-due) try again.
  2. Less than MIN_FREE_GIB free on the volume -> "refusing to start", exit 1.
  3. HomeLab unreachable (every source is probed first) -> "skipped: HomeLab not reachable", exit 3, nothing synced.
     Another run in progress (a long first copy, a manual run) holds <volume>/mirror/.lock: "skipped: a run is already in
     progress", exit 0 (that run is the work). Two syncs into one mirror would fight over the same files.
  4. `rclone sync` per source, comparing size and modification time. A file changed or deleted at the source is MOVED
     to <volume>/mirror/.deleted/<YYYY-MM-DD>/<source>/ (--backup-dir), never removed; those dated folders are deleted after
     RETAIN_DAYS (30). What restic leaves out (FILTERS below) is left out here too.
  5. Monthly (CHECK_EVERY_DAYS): `rclone check --download` over a seeded sample of each source's files; what it found is
     recorded in the status file. A difference makes the run exit 1.
  6. <volume>/mirror/.status.json: started, finished, ok, free_gib, per source files, bytes, transferred, errors, and `check`.
Exit 1 when any sync or check failed, so `jobs-grade` shows the job failing.
Each source that synced clean is stamped in STATE_DIR/last-ok.json (outside the volume, so a volume that cannot be read still
has an age); scripts/ext-mirror-check.sh turns a stamp older than 36 h into a heartbeat FAIL.

  ext-mirror.py              one run (through the gate)
  ext-mirror.py --if-due     what the job runs: skips (exit 0, or 1 while the last run was red) when the last run is recent
                             enough, decided from STATE_DIR/last-run.json before the volume gate, so the hourly triggers cost
                             a second and never touch the volume once the night's copy is done
  ext-mirror.py --dry-run    rclone --dry-run: nothing written, no status, no prune
  ext-mirror.py --check-now  run the sample check this time whatever its last date
  ext-mirror.py --status     print the status file (through the gate)

Env (tests and manual runs): HL_BIN, RCLONE_BIN, EXT_MIRROR_{MIN_FREE_GIB,RETAIN_DAYS,CHECK_EVERY_DAYS,CHECK_SAMPLE_FILES,
CHECK_SAMPLE_BYTES,PROBE_TIMEOUT_S,TRANSFERS,GATE,DUE_AFTER_H,RETRY_FAILED_AFTER_H,STATE_DIR}; the gate's own VOLUME_GATE_{CONFIG,DISKUTIL}. Contract: docs/storage.md §EXT mirror.
"""
import datetime
import fcntl
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GIB = 1024 ** 3
SECRET_ERRORS = ("could not resolve", "config incomplete", "missing required tool", "cannot pick a key")
# What a HomeLab that is away looks like (tailnet down, the gateway restarting). Anything else that fails the probe, such as
# AccessDenied or a signature error from a rotated key, is a failure and must not hide behind a skipped night.
AWAY_ERRORS = ("no such host", "i/o timeout", "connection refused", "no route to host", "network is unreachable",
               "timed out", "connection reset", "request send failed", "tls handshake timeout")
SKIP_RC = 3  # a skipped run (volume or HomeLab away) exits with this, never 0: nothing ran, so the grade must not be green
DATE_DIR = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# (name under <volume>/mirror, remote). The HomeLab's HDD/fuji holds RAWs and Videos; HDD/Videos is the owner's other big videos.
SOURCES = [("ssd", "homelab:ssd"), ("fuji", "homelab:hdd/fuji"), ("videos", "homelab:hdd/Videos")]

# What the HomeLab's restic run leaves out (homelab repo, restic-excludes.txt), as rclone filter rules. `*.tmp` is NOT
# among them: it dropped a real 1.3 GiB phone video from the offsite copy (docs/storage.md). `.sgwtmp` is the S3
# gateway's own scratch folder. `.XDG/wayland-N` is a Wayland socket (calibre's container config) stored as a 0-byte
# object the gateway cannot serve: GetObject is a 500 for ever, which made every night's `ssd` sync red (issue 1850).
FILTERS = """\
- .DS_Store
- ._*
- .AppleDouble
- .LSOverride
- .Spotlight-V100/**
- .Trashes/**
- .fseventsd/**
- .Trash-*/**
- **/.trash/**
- .sgwtmp/**
- **/.sgwtmp/**
- *.swp
- *.swo
- *~
- **/node_modules/**
- **/.next/**
- **/.nuxt/**
- **/dist/**
- **/build/**
- **/target/**
- **/.cache/**
- **/.venv/**
- **/__pycache__/**
- **/*.pyc
- **/.tmp/**
- *-shm
- *-journal
- **/immich/encoded-video/**
- **/immich/thumbs/**
- **/immich/profile/**
- **/immich/library/preview/**
- **/immich/library/thumb/**
- **/immich/postgres/**
- **/protonmail/bridge-v3/gluon/**
- **/protonmail/bridge-v3/logs/**
- **/.XDG/wayland-[0-9]
"""


class Cfg:
    def __init__(self):
        e = os.environ.get
        self.hl = e("HL_BIN", os.path.join(HERE, "hl"))
        self.rclone = e("RCLONE_BIN", "rclone")
        self.gate = e("EXT_MIRROR_GATE", os.path.join(HERE, "lib", "volume-gate.sh"))
        self.min_free_gib = float(e("EXT_MIRROR_MIN_FREE_GIB", "60"))
        self.retain_days = int(e("EXT_MIRROR_RETAIN_DAYS", "30"))
        self.check_every_days = int(e("EXT_MIRROR_CHECK_EVERY_DAYS", "30"))
        self.sample_files = int(e("EXT_MIRROR_CHECK_SAMPLE_FILES", "100"))
        self.sample_bytes = int(e("EXT_MIRROR_CHECK_SAMPLE_BYTES", str(1 * GIB)))
        self.probe_timeout = int(e("EXT_MIRROR_PROBE_TIMEOUT_S", "120"))
        # The path to the HomeLab carries about 9 MiB/s over 16 streams (docs/storage.md §EXT mirror); streams keep small files from queueing.
        self.transfers = int(e("EXT_MIRROR_TRANSFERS", "16"))
        # --if-due: a clean run is due again after 18 h (the 05:00 trigger of the next night), a red one after 6 h.
        self.due_after_h = float(e("EXT_MIRROR_DUE_AFTER_H", "18"))
        self.retry_failed_after_h = float(e("EXT_MIRROR_RETRY_FAILED_AFTER_H", "6"))
        self.state_dir = e("EXT_MIRROR_STATE_DIR", os.path.join(os.path.expanduser("~"), ".local", "state", "ext-mirror"))
        # tailscaled does the WireGuard work for every byte (measured 2026-11-16: 0.45 core at 5 MiB/s, docs/host-waste.md §tailscaled), so by
        # day the copy is held to 4 MiB/s (about 0.35 core); an rclone timetable, "" = unlimited. Catch-ups after days away run slower by day.
        self.bwlimit = e("EXT_MIRROR_BWLIMIT", "07:00,4M 23:00,off")


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def write_json(path, obj):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def run(argv, timeout=None, data=False):
    """(rc, output): stdout and stderr together, or stdout alone when `data` (a listing, JSON). A timeout is rc 124."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    return p.returncode, (p.stdout if data else p.stdout + p.stderr).strip()


def stream_rclone(argv):
    """Run an rclone command that logs JSON; return (rc, last stats object, first error messages)."""
    stats, errors = {}, []
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    for line in p.stdout:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        if isinstance(rec.get("stats"), dict):
            stats = rec["stats"]
        if rec.get("level") == "error" and len(errors) < 10:
            # rclone puts the file in `object`, not in the message: without it a red night names no file.
            obj = f"[{rec['object']}] " if rec.get("object") else ""
            errors.append(f"{obj}{rec.get('msg', '')}"[:300])
    return p.wait(), stats, errors


def filter_file(tmpdir):
    path = os.path.join(tmpdir, "filters.txt")
    with open(path, "w") as f:
        f.write(FILTERS)
    return path


def local_size(cfg, flt, path):
    rc, out = run([cfg.rclone, "size", "--json", "--filter-from", flt, path], data=True)
    if rc != 0:
        return None, None
    try:
        j = json.loads(out)
        return j["count"], j["bytes"]
    except (ValueError, KeyError):
        return None, None


def probe(cfg, remote):
    """('ok', n entries) | ('away', why) | ('secret', why) | ('failed', why)."""
    rc, out = run([cfg.hl, "lsf", "--max-depth", "1", remote], timeout=cfg.probe_timeout)
    if rc == 0:
        return "ok", len([ln for ln in out.splitlines() if ln.strip()])
    if any(s in out for s in SECRET_ERRORS):
        return "secret", out[-200:]
    if rc == 124 or any(a in out.lower() for a in AWAY_ERRORS):
        return "away", out[-200:] or "no output"
    return "failed", out[-200:] or "no output"


def sync_source(cfg, flt, mirror, name, remote, day, dry):
    dest = os.path.join(mirror, name)
    backup = os.path.join(mirror, ".deleted", day, name)
    os.makedirs(dest, exist_ok=True)
    argv = [cfg.hl, "sync", remote, dest, "--backup-dir", backup, "--filter-from", flt, "--create-empty-src-dirs",
            "--transfers", str(cfg.transfers), "--checkers", "16", "--retries", "3", "--low-level-retries", "10",
            "--use-json-log", "--stats", "600s", "--stats-log-level", "NOTICE"]
    if cfg.bwlimit:
        argv += ["--bwlimit", cfg.bwlimit]
    if dry:
        argv.append("--dry-run")
    rc, stats, errors = stream_rclone(argv)
    res = {
        "ok": rc == 0 and not stats.get("errors"),
        "transferred": int(stats.get("transfers", 0)),
        "transferred_bytes": int(stats.get("bytes", 0)),
        "moved_to_deleted": sum(len(fs) for _d, _ds, fs in os.walk(backup)),  # everything held under today's folder
        "errors": int(stats.get("errors", 0)) or (1 if rc != 0 else 0),
    }
    if errors:
        res["error_messages"] = errors
    files, size = (None, None) if dry else local_size(cfg, flt, dest)
    res["files"], res["bytes"] = files, size
    return res


def prune_deleted(mirror, retain_days):
    """Remove .deleted/<date> folders older than retain_days. Only folders named like a date are ever touched."""
    root = os.path.join(mirror, ".deleted")
    if not os.path.isdir(root):
        return []
    cutoff = datetime.date.today() - datetime.timedelta(days=retain_days)
    removed = []
    for d in sorted(os.listdir(root)):
        if not DATE_DIR.match(d):
            continue
        try:
            when = datetime.date.fromisoformat(d)
        except ValueError:
            continue
        if when < cutoff:
            shutil.rmtree(os.path.join(root, d), ignore_errors=True)
            removed.append(d)
    return removed


def sample_files(cfg, flt, dest, seed):
    """Seeded sample of the mirror's own files: (relative paths, bytes). Same seed and content = same sample."""
    rc, out = run([cfg.rclone, "lsf", "-R", "--files-only", "--format", "sp", "--separator", "\t", "--filter-from", flt, dest],
                  data=True)
    if rc != 0:
        return None, 0
    rows = []
    for line in out.splitlines():
        size, sep, path = line.partition("\t")
        if sep and size.isdigit():
            rows.append((path, int(size)))
    random.Random(seed).shuffle(rows)
    picked, total = [], 0
    for path, size in rows:
        if len(picked) >= cfg.sample_files or total + size > cfg.sample_bytes:
            continue
        picked.append(path)
        total += size
    return picked, total


def check_source(cfg, flt, mirror, name, remote, seed, tmpdir):
    """rclone check --download over the sample; the combined report says what each file was."""
    dest = os.path.join(mirror, name)
    picked, total = sample_files(cfg, flt, dest, f"{seed}-{name}")
    if picked is None:
        return {"ok": False, "error": "could not list the mirror"}
    if not picked:
        return {"ok": True, "sampled": 0, "bytes": 0, "matched": 0, "differ": 0, "missing_in_mirror": 0, "errors": 0}
    listing = os.path.join(tmpdir, f"{name}.files")
    report = os.path.join(tmpdir, f"{name}.combined")
    with open(listing, "w") as f:
        f.write("\n".join(picked) + "\n")
    check_argv = [cfg.hl, "check", remote, dest, "--download", "--one-way", "--files-from", listing,
                  "--combined", report, "--checkers", str(cfg.transfers), "--use-json-log", "--stats", "0"]
    if cfg.bwlimit:
        check_argv += ["--bwlimit", cfg.bwlimit]
    rc, _stats, _errs = stream_rclone(check_argv)
    counts = {"=": 0, "*": 0, "+": 0, "-": 0, "!": 0}
    try:
        with open(report, errors="replace") as f:
            for line in f:
                if line[:2] in ("= ", "* ", "+ ", "- ", "! "):
                    counts[line[0]] += 1
    except OSError:
        return {"ok": False, "error": f"check produced no report (rc {rc})"}
    res = {"sampled": len(picked), "bytes": total, "matched": counts["="], "differ": counts["*"],
           "missing_in_mirror": counts["+"], "errors": counts["!"]}
    res["ok"] = rc == 0 and counts["*"] == 0 and counts["+"] == 0 and counts["!"] == 0
    return res


def run_due(cfg, status):
    """(due, why). No finished run on record, or the last one older than its threshold: due."""
    try:
        when = datetime.datetime.strptime(status.get("finished", ""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (ValueError, TypeError):
        return True, "no finished run on record"
    age_h = (datetime.datetime.now(datetime.timezone.utc) - when).total_seconds() / 3600
    limit = cfg.due_after_h if status.get("ok") else cfg.retry_failed_after_h
    if age_h >= limit:
        return True, f"the last run finished {age_h:.1f} h ago"
    return False, f"the last run{'' if status.get('ok') else ' (FAILED)'} finished {age_h:.1f} h ago, due after {limit:g} h"


def stamp_ok_sources(cfg, results, finished, keep_newer=False):
    """Remember, outside the volume, when each source last synced clean. A source that failed keeps its older stamp;
    keep_newer: never move a stamp back (stamping from an old status file)."""
    path = os.path.join(cfg.state_dir, "last-ok.json")
    stamps = read_status(path)
    for name, r in results.items():
        if r.get("ok") and not (keep_newer and stamps.get(name, "") >= finished):
            stamps[name] = finished
    os.makedirs(cfg.state_dir, exist_ok=True)
    write_json(path, stamps)


def write_last_run(cfg, finished, ok):
    """The last finished run, kept outside the volume: --if-due decides from it before the gate, so a trigger with nothing to do
    never touches the volume and a stalled sentinel read at 14:00 cannot turn a clean mirror red."""
    os.makedirs(cfg.state_dir, exist_ok=True)
    write_json(os.path.join(cfg.state_dir, "last-run.json"), {"finished": finished, "ok": bool(ok)})


def not_due_before_the_gate(cfg, args):
    """Exit code when --if-due finds nothing to do from the local record alone, else None (go through the gate)."""
    if "--if-due" not in args or "--dry-run" in args or "--status" in args:
        return None
    last = read_status(os.path.join(cfg.state_dir, "last-run.json"))
    if not last.get("finished"):
        return None
    due, why = run_due(cfg, last)
    if due:
        return None
    red = not last.get("ok")
    log(f"not due: {why}" + ("; the mirror is red until a run passes" if red else ""))
    return 1 if red else 0


def check_due(cfg, status, force):
    if force or not (status.get("check") or {}).get("ok", True):
        return True  # a failed check is tried again the next night, so one repaired file does not hold the job red for a month
    last = (status.get("check") or {}).get("finished")
    if not last:
        return True
    try:
        when = datetime.datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return True
    return (datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - when).days >= cfg.check_every_days


def read_status(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def run_inside_gate(cfg, args):
    root = os.environ.get("VOLUME_ROOT", "")
    if not root or not os.path.isdir(root):
        log("FAILED: VOLUME_ROOT missing: this runs through volume-gate.sh")
        return 1
    mirror = os.path.join(root, "mirror")
    status_path = os.path.join(mirror, ".status.json")
    dry = "--dry-run" in args

    if "--status" in args:
        print(json.dumps(read_status(status_path), indent=1, sort_keys=True))
        return 0

    if "--if-due" in args and not dry:
        due, why = run_due(cfg, read_status(status_path))
        if not due:
            prev = read_status(status_path)
            red = not prev.get("ok")
            if prev.get("finished"):  # a run made before the stamps existed (or with the state lost) still counts
                stamp_ok_sources(cfg, prev.get("sources", {}), prev["finished"], keep_newer=True)
                write_last_run(cfg, prev["finished"], prev.get("ok"))
            log(f"not due: {why}" + ("; the mirror is red until a run passes" if red else ""))
            return 1 if red else 0
        log(f"due: {why}")

    free = shutil.disk_usage(root).free / GIB
    if free < cfg.min_free_gib:
        log(f"FAILED: refusing to start: {free:.0f} GiB free on the volume, the floor is {cfg.min_free_gib:.0f} GiB")
        return 1

    # Probe every source before anything is synced: a HomeLab that is away is a skipped night, not a half-synced one.
    listed = {}
    for name, remote in SOURCES:
        state, detail = probe(cfg, remote)
        if state == "secret":
            log(f"FAILED: hl cannot resolve its key: {detail}")
            return 1
        if state == "failed":
            log(f"FAILED: probe of {remote} failed: {detail}")
            return 1
        if state == "away":
            log(f"skipped: HomeLab not reachable ({detail})")
            return SKIP_RC
        listed[name] = detail

    os.makedirs(mirror, exist_ok=True)
    lock = open(os.path.join(mirror, ".lock"), "w")  # held until this process ends, whatever way it ends
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("skipped: a run is already in progress")
        return 0

    started = now_utc()
    day = datetime.date.today().isoformat()
    previous = read_status(status_path)
    os.makedirs(mirror, exist_ok=True)
    results = {}
    with tempfile.TemporaryDirectory(prefix="ext-mirror.") as tmpdir:
        flt = filter_file(tmpdir)
        for name, remote in SOURCES:
            dest = os.path.join(mirror, name)
            # An empty listing over a non-empty mirror is a share that is not mounted at home, not a deletion of everything.
            if listed[name] == 0 and os.path.isdir(dest) and os.listdir(dest):
                results[name] = {"ok": False, "errors": 1, "transferred": 0, "transferred_bytes": 0, "moved_to_deleted": 0,
                                 "files": None, "bytes": None, "error_messages": ["the source lists empty; sync refused"]}
                log(f"FAILED: {name}: {remote} lists empty while the mirror holds files; sync refused")
                continue
            log(f"sync {name}: {remote}")
            results[name] = sync_source(cfg, flt, mirror, name, remote, day, dry)
            r = results[name]
            log(f"{'ok' if r['ok'] else 'FAILED'} {name}: files={r['files']} bytes={r['bytes']} transferred={r['transferred']} "
                f"moved_to_deleted={r['moved_to_deleted']} errors={r['errors']}")
            for m in r.get("error_messages", []):
                log(f"  {m}")

        check = previous.get("check")
        if not dry and check_due(cfg, previous, "--check-now" in args):
            log("sample check (rclone check --download)")
            seed = datetime.date.today().strftime("%Y-%m")
            per = {}
            for name, remote in SOURCES:
                if results[name]["errors"]:
                    continue  # a source that failed to sync is already red; a check over a half-synced mirror proves nothing
                per[name] = check_source(cfg, flt, mirror, name, remote, seed, tmpdir)
                c = per[name]
                log(f"check {name}: {'ok' if c['ok'] else 'FAILED'} "
                    f"sampled={c.get('sampled')} differ={c.get('differ')} missing={c.get('missing_in_mirror')} errors={c.get('errors')}")
            if len(per) < len(SOURCES):
                # A source that did not sync was not checked: keep the earlier record, so the check stays due and a failed one is not erased.
                log("sample check incomplete: a source failed to sync; the check stays due")
            else:
                check = {"finished": now_utc(), "seed": seed, "ok": all(c["ok"] for c in per.values()), "sources": per}

    removed = [] if dry else prune_deleted(mirror, cfg.retain_days)
    if removed:
        log(f"pruned .deleted: {', '.join(removed)}")

    ok = all(r["ok"] for r in results.values()) and (check is None or check.get("ok", True))
    if not dry:
        finished = now_utc()
        stamp_ok_sources(cfg, results, finished)
        write_last_run(cfg, finished, ok)
        status = {"started": started, "finished": finished, "ok": ok, "free_gib": round(shutil.disk_usage(root).free / GIB, 1),
                  "sources": {n: {k: v for k, v in r.items() if k != "ok"} | {"ok": r["ok"]} for n, r in results.items()}}
        if check is not None:
            status["check"] = check
        write_json(status_path, status)
    log("done" if ok else "FAILED: see the lines above")
    return 0 if ok else 1


def main(argv):
    cfg = Cfg()
    args = argv[1:]
    if "--inner" in args:
        return run_inside_gate(cfg, [a for a in args if a != "--inner"])
    early = not_due_before_the_gate(cfg, args)
    if early is not None:
        return early
    # Not inside the gate yet: hand over to it. The gate sets VOLUME_ROOT, or prints its one skipped line and exits SKIP_RC.
    os.execv(cfg.gate, [cfg.gate, "run", "--skip-rc", str(SKIP_RC), "--", sys.executable, os.path.abspath(__file__), "--inner", *args])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
