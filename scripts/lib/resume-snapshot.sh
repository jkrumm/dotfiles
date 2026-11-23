#!/usr/bin/env bash
# resume-snapshot.sh — record the resumable Claude terminals of the mini before it reboots. Sourced, not run.
#
#   . "$HERE/lib/resume-snapshot.sh"
#   resume_snapshot <host> <stamp>      # stamp: YYYYmmdd-HHMM, names the file on the host
#
# Terminals survive a core restart but not a reboot. hc-resume revives Claude from the resume labels
# (jk.claude.session / jk.claude.config, hooks/hc-session-label.ts) once the core is back, and this file is the
# human-readable record of what it should find: ~/Library/Logs/herdr-core-resume-pre-reboot-<stamp>.tsv on the host
# (address, session, config, cwd, state). Best effort: never blocks, never fails the caller, and runs `lib/core-up.sh`
# first because any `hc` call auto-starts a stray core. Shared by mini-macos-update.sh and mini-reboot.sh.
# Overrides (tests): SSH_BIN.

resume_snapshot() {
  local host="$1" stamp="$2" core_snap core_n=""
  core_snap="\$HOME/Library/Logs/herdr-core-resume-pre-reboot-$stamp.tsv"
  # shellcheck disable=SC2029  # $core_snap is built here on purpose; \$HOME expands on the host
  if core_n=$("${SSH_BIN:-ssh}" -o ConnectTimeout=6 -o BatchMode=yes "$host" "/usr/bin/python3 - $core_snap" <<'PY' 2>/dev/null
import json, os, subprocess, sys
up = subprocess.run(["/bin/bash", os.path.expanduser("~/SourceRoot/dotfiles/scripts/lib/core-up.sh")], capture_output=True)
if up.returncode != 0:
    sys.exit(3)
hc = os.path.expanduser("~/.local/bin/hc")
def run(*a):
    return json.loads(subprocess.run([hc, *a, "--json"], capture_output=True, text=True, check=True, timeout=20).stdout)
rows = []
for t in run("ls").get("terminals", []):
    d = run("get", t["address"])
    lab = d.get("labels") or {}
    if lab.get("jk.claude.session"):
        rows.append("\t".join([d["address"], lab["jk.claude.session"], lab.get("jk.claude.config", ""), d.get("cwd") or "", d.get("state") or ""]))
with open(sys.argv[1], "w") as f:
    f.write("\n".join(rows) + ("\n" if rows else ""))
print(len(rows))
PY
)
  then
    echo "  · $core_n resumable Claude terminal(s) snapshotted to $core_snap on $host (address, session, config, cwd, state)"
  else
    echo "  · herdr-core resume snapshot skipped (core not running or not answering)"
  fi
  return 0
}
