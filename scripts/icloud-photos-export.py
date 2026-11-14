#!/usr/bin/env python3
"""icloud-photos-export — the nightly archive of the mini's iCloud Photos library on the HomeLab.

The mini is signed in to iCloud Photos with "Download Originals to this Mac"; this job never talks to
Photos or to Apple. It reads the library files with osxphotos (read-only) and copies what is new or
changed to `homelab:ssd/Bilder/iCloud/<year>/<month>/` with `hl` (S3). The export is an ARCHIVE: nothing
is ever deleted, an asset removed or trashed in Photos stays where it was put.

Per run:
  1. HomeLab unreachable -> "skipped", exit 0. Less than MIN_FREE_GIB free on the Data volume -> exit 1.
  2. Ask osxphotos (through the herdr core, which holds Full Disk Access: `hc exec`, only while scripts/lib/core-up.sh says the launchd-born core is up) for every library
     asset that is not trashed and not in a shared album, with its modification stamp and local files.
  3. A ledger (state dir, copy at <dest>/.ledger.json) says which asset was exported at which stamp. New or
     changed assets whose files are on disk are exported in batches into a staging dir (original, the
     `_edited` version, a Live Photo's .mov next to its still), uploaded, size-checked, recorded, and
     the staging dir is emptied. Assets whose files are not on disk yet (Photos still downloading) are
     `pending_local` and tried again tomorrow.
  4. <dest>/.status.json (and a local copy) hold the counts. Exit 1 when any asset failed, so jobs-grade shows it.

  icloud-photos-export.py            run once
  icloud-photos-export.py --status   print the last status file

Env (tests and manual runs): ICLOUD_EXPORT_{LIBRARY,STATE,DEST,MAX_ASSETS,MAX_BYTES,DEADLINE_S,MIN_FREE_GIB,
RUNNER (hc|direct)}, OSXPHOTOS_BIN, HL_BIN, HC_BIN. Contract and rationale: docs/storage.md §iCloud Photos export.
"""
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
GIB = 1024 ** 3
UUID_LINE = re.compile(r"^[^|\s]+\|")  # osxphotos' progress lines have spaces and no pipe
SECRET_ERRORS = ("could not resolve", "config incomplete", "missing required tool", "cannot pick a key")
PRINT_TEMPLATE = "|".join(
    ["{uuid}", "{photo.date_modified}", "{photo.date_added}", "{photo.hasadjustments}", "{photo.original_filesize}",
     "{photo.path}", "{photo.path_edited}", "{photo.path_live_photo}", "{photo.live_photo}", "{photo.date}"])
FILENAME_TEMPLATE = "{created.strftime,%Y-%m-%d_%H%M%S}_{original_name}"
DIRECTORY_TEMPLATE = "{created.year}/{created.mm}"


class Cfg:
    def __init__(self):
        e = os.environ.get
        self.library = e("ICLOUD_EXPORT_LIBRARY", f"{HOME}/Pictures/Photos Library.photoslibrary")
        self.state = e("ICLOUD_EXPORT_STATE", f"{HOME}/.local/state/icloud-photos-export")
        self.dest = e("ICLOUD_EXPORT_DEST", "homelab:ssd/Bilder/iCloud").rstrip("/")
        self.max_assets = int(e("ICLOUD_EXPORT_MAX_ASSETS", "1000"))
        self.max_bytes = int(e("ICLOUD_EXPORT_MAX_BYTES", str(10 * GIB)))
        self.deadline_s = int(e("ICLOUD_EXPORT_DEADLINE_S", "6000"))
        self.min_free_gib = float(e("ICLOUD_EXPORT_MIN_FREE_GIB", "40"))
        self.runner = e("ICLOUD_EXPORT_RUNNER", "hc")
        self.osxphotos = e("OSXPHOTOS_BIN", f"{HOME}/.local/bin/osxphotos")
        self.hl = e("HL_BIN", "hl")
        self.hc = e("HC_BIN", "hc")
        self.core_up = e("ICLOUD_EXPORT_CORE_UP", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "core-up.sh"))
        self.step_timeout = int(e("ICLOUD_EXPORT_STEP_TIMEOUT", "600"))  # hc exec ends at 600
        self.stage = os.path.join(self.state, "stage")
        self.ledger_path = os.path.join(self.state, "ledger.json")
        self.status_path = os.path.join(self.state, "status.json")


def log(msg):
    print(f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def write_json(path, obj):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def sh_in_core(cfg, script, *args):
    """Run `sh -c script args` where Full Disk Access is: inside the herdr core (`hc exec`), or directly."""
    argv = ["/bin/sh", "-c", script, *args]
    if cfg.runner == "hc":
        argv = [cfg.hc, "exec", "--timeout", str(cfg.step_timeout), *argv]
    return subprocess.run(argv, capture_output=True, text=True).returncode


def hl(cfg, *args):
    p = subprocess.run([cfg.hl, *args], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def free_gib():
    return shutil.disk_usage(HOME).free / GIB


def signature(row):
    stamp = row["date_modified"] or row["date_added"]
    return f"{stamp}|{row['hasadjustments']}|{row['original_filesize']}|{row['path_edited'] is not None}"


def parse_query(path):
    rows = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not UUID_LINE.match(line):
                continue
            p = line.split("|")
            if len(p) != 10:
                continue
            none = lambda v: None if v == "_" else v  # noqa: E731 - osxphotos prints `_` for empty
            rows.append({
                "uuid": p[0], "date_modified": none(p[1]), "date_added": none(p[2]),
                "hasadjustments": none(p[3]) is not None, "original_filesize": int(p[4]) if p[4].isdigit() else 0,
                "path": none(p[5]), "path_edited": none(p[6]), "path_live_photo": none(p[7]),
                "live_photo": none(p[8]) is not None, "date": p[9],
            })
    rows.sort(key=lambda r: (r["date"], r["uuid"]))
    return rows


def local_ready(row):
    """The files the export needs are on disk: the original, the edit render, the Live Photo's video."""
    if not row["path"] or not os.path.exists(row["path"]):
        return False
    if row["hasadjustments"] and not (row["path_edited"] and os.path.exists(row["path_edited"])):
        return False
    if row["live_photo"] and not (row["path_live_photo"] and os.path.exists(row["path_live_photo"])):
        return False
    return True


def batches(work, cfg):
    cur, size = [], 0
    for row in work:
        if cur and (len(cur) >= cfg.max_assets or size + row["original_filesize"] > cfg.max_bytes):
            yield cur
            cur, size = [], 0
        cur.append(row)
        size += row["original_filesize"]
    if cur:
        yield cur


def export_batch(cfg, batch, ledger):
    """Export one batch into a clean staging dir. Returns (ok_uuids, pending_uuids, failed_uuids, error or None);
    files of assets that are not ok are removed from staging."""
    shutil.rmtree(cfg.stage, ignore_errors=True)
    os.makedirs(cfg.stage)
    uuid_file = os.path.join(cfg.state, "batch-uuids.txt")
    report = os.path.join(cfg.state, "batch-report.json")
    out = os.path.join(cfg.state, "batch-export.log")
    with open(uuid_file, "w") as f:
        f.write("\n".join(r["uuid"] for r in batch) + "\n")
    if os.path.exists(report):
        os.remove(report)
    script = (
        'exec "$0" export "$1" --library "$2" --uuid-from-file "$3" --directory "$4" --filename "$5" '
        '--edited-suffix _edited --no-progress --report "$6" --exportdb "$7" >"$8" 2>&1')
    rc = sh_in_core(cfg, script, cfg.osxphotos, cfg.stage, cfg.library, uuid_file, DIRECTORY_TEMPLATE,
                    FILENAME_TEMPLATE, report, os.path.join(cfg.state, "osxphotos-scratch.db"), out)
    if rc != 0 or not os.path.exists(report):
        return [], [], [], f"osxphotos export rc={rc} (log {out})"
    with open(report) as f:
        rows = json.load(f)
    by_uuid = {}
    for r in rows:
        by_uuid.setdefault(r["uuid"], []).append(r)
    stage_real = os.path.realpath(cfg.stage)
    taken = {name: u for u, e in ledger["assets"].items() for name in e["files"]}
    ok, pending, failed = [], [], []
    for row in batch:
        u = row["uuid"]
        files = by_uuid.get(u, [])
        rels = [os.path.relpath(os.path.realpath(r["filename"]), stage_real) for r in files]
        if any(r.get("error") for r in files):
            failed.append((u, "; ".join(r["error"] for r in files if r.get("error"))))
        elif any(r.get("missing") for r in files) or not files:
            pending.append(u)
        elif any(taken.get(rel, u) != u for rel in rels):
            failed.append((u, f"name collision with another asset: {rels}"))
        else:
            ok.append((u, rels))
            continue
        for r in files:
            if os.path.exists(r["filename"]):
                os.remove(r["filename"])
    for name in os.listdir(cfg.stage):  # osxphotos' own bookkeeping never goes up
        if name.startswith(".osxphotos"):
            os.remove(os.path.join(cfg.stage, name))
    return ok, pending, failed, None


def upload_batch(cfg):
    rc, out = hl(cfg, "copy", cfg.stage, cfg.dest)
    if rc != 0:
        return f"hl copy failed: {out[-300:]}"
    rc, out = hl(cfg, "check", cfg.stage, cfg.dest, "--one-way")
    if rc != 0:
        return f"hl check failed: {out[-300:]}"
    return None


def dir_bytes(path):
    return sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)


def load_ledger(cfg):
    if not os.path.exists(cfg.ledger_path):
        hl(cfg, "copyto", f"{cfg.dest}/.ledger.json", cfg.ledger_path)  # state lost: take the copy next to the export
    if os.path.exists(cfg.ledger_path):
        with open(cfg.ledger_path) as f:
            return json.load(f)
    return {"version": 1, "assets": {}}


def run(cfg):
    t0 = time.monotonic()
    os.makedirs(cfg.state, exist_ok=True)
    rc, out = hl(cfg, "lsd", cfg.dest.split("/")[0] + "/" + cfg.dest.split("/")[1])
    if rc != 0:
        if any(s in out for s in SECRET_ERRORS):
            log(f"FAILED: hl cannot authenticate: {out[-300:]}")
            return 1
        log(f"skipped: HomeLab not reachable ({out[-200:] or 'no output'})")
        return 0
    free = free_gib()
    if free < cfg.min_free_gib:
        log(f"FAILED: {free:.0f} GiB free on the Data volume, below the {cfg.min_free_gib:.0f} GiB floor; nothing exported")
        return 1

    if cfg.runner == "hc":  # any `hc` call starts a core when none answers: a stray one has no Full Disk Access
        p = subprocess.run(["bash", cfg.core_up], capture_output=True, text=True)
        if p.returncode != 0:
            log(f"FAILED: the herdr core is not up, nothing read ({(p.stdout + p.stderr).strip()[-300:]})")
            return 1

    ledger = load_ledger(cfg)
    query_out = os.path.join(cfg.state, "query.txt")
    count_out = os.path.join(cfg.state, "shared-count.txt")
    rc1 = sh_in_core(cfg, 'exec "$0" query --library "$1" --not-shared --print "$2" >"$3" 2>"$3.err"',
                     cfg.osxphotos, cfg.library, PRINT_TEMPLATE, query_out)
    sh_in_core(cfg, 'exec "$0" query --library "$1" --shared --count >"$2" 2>/dev/null',
               cfg.osxphotos, cfg.library, count_out)
    if rc1 != 0:
        log(f"FAILED: osxphotos query rc={rc1} (see {query_out}.err)")
        return 1
    rows = parse_query(query_out)
    if not rows and ledger["assets"]:
        log("FAILED: the library query returned no assets while the ledger has some; refusing to continue")
        return 1
    try:
        shared = int(open(count_out).read().strip().splitlines()[-1])
    except (OSError, ValueError, IndexError):
        shared = None

    work, pending, unchanged, changed = [], 0, 0, 0
    for row in rows:
        entry = ledger["assets"].get(row["uuid"])
        if entry and entry["sig"] == signature(row):
            unchanged += 1
            continue
        if not local_ready(row):
            pending += 1
            continue
        if entry:
            changed += 1
        work.append(row)
    log(f"library {len(rows)} assets, {unchanged} unchanged, {len(work)} to export ({changed} changed), {pending} not on disk yet")

    new_assets, failed, uploaded, aborted = 0, [], 0, None
    for batch in batches(work, cfg):
        if time.monotonic() - t0 > cfg.deadline_s:
            log("deadline reached, the rest goes tomorrow")
            break
        if free_gib() < cfg.min_free_gib:
            aborted = f"free space fell below {cfg.min_free_gib:.0f} GiB"
            break
        ok, miss, bad, err = export_batch(cfg, batch, ledger)
        if err:
            aborted = err
            break
        pending += len(miss)
        failed += bad
        if ok:
            err = upload_batch(cfg)
            if err:
                aborted = err
                break
            size = dir_bytes(cfg.stage)
            uploaded += size
            by_uuid = {r["uuid"]: r for r in batch}
            for u, rels in ok:
                if u not in ledger["assets"]:
                    new_assets += 1
                ledger["assets"][u] = {"sig": signature(by_uuid[u]), "files": rels,
                                       "exported": datetime.datetime.now().isoformat(timespec="seconds")}
            write_json(cfg.ledger_path, ledger)
        log(f"batch: {len(ok)} exported, {len(miss)} not on disk, {len(bad)} failed")
        shutil.rmtree(cfg.stage, ignore_errors=True)
    shutil.rmtree(cfg.stage, ignore_errors=True)
    for u, why in failed:
        log(f"FAILED asset {u}: {why}")
    if aborted:
        log(f"FAILED: {aborted}")

    in_library = {r["uuid"] for r in rows}
    status = {
        "library_assets": len(rows), "shared_album_assets_excluded": shared,
        "exported_assets": sum(1 for u in ledger["assets"] if u in in_library),
        "kept_after_removal": sum(1 for u in ledger["assets"] if u not in in_library),
        "pending_local": pending, "new_this_run": new_assets, "changed_this_run": changed if not aborted else None,
        "failed": len(failed), "bytes_uploaded_this_run": uploaded, "free_gib": round(free_gib(), 1),
        "finished": datetime.datetime.now().isoformat(timespec="seconds"),
        "duration_s": round(time.monotonic() - t0), "aborted": aborted,
        "last_ok": datetime.datetime.now().isoformat(timespec="seconds") if not (failed or aborted) else None,
    }
    if status["last_ok"] is None and os.path.exists(cfg.status_path):
        with open(cfg.status_path) as f:
            status["last_ok"] = json.load(f).get("last_ok")
    write_json(cfg.status_path, status)
    write_json(cfg.ledger_path, ledger)
    for name, path in ((".status.json", cfg.status_path), (".ledger.json", cfg.ledger_path)):
        rc, out = hl(cfg, "copyto", path, f"{cfg.dest}/{name}")
        if rc != 0:
            log(f"FAILED: could not write {name} next to the export: {out[-200:]}")
            return 1
    log("status " + json.dumps(status, sort_keys=True))
    return 1 if failed or aborted else 0


def main(argv):
    cfg = Cfg()
    if argv[1:] == ["--status"]:
        try:
            print(open(cfg.status_path).read())
        except OSError:
            print("no run recorded yet", file=sys.stderr)
            return 1
        return 0
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    if cfg.runner == "hc" and shutil.which(cfg.hc) is None:
        log("FAILED: hc not found (the herdr core is how this job gets Full Disk Access)")
        return 1
    return run(cfg)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
