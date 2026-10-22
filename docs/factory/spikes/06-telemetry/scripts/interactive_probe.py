#!/usr/bin/env python3
"""Drive an INTERACTIVE `claude` (the herdr / `rd wave` shape) inside a pty, then exit it cleanly.

Question it answers (Spike 6): Claude Code docs say interactive sessions IGNORE an inbound
TRACEPARENT (only `-p` / Agent SDK sessions read it). herdr workers are interactive TUIs, so this
measures what actually joins when the worker is not headless.

  python3 -I interactive_probe.py --cwd <dir> --prompt-file <file> --mcp-config <json> \
      --done-marker PROBE_FINISHED --transcript <out.txt>

It launches the same IU credentials `claude_iu` uses (macOS Keychain, read by the child shell,
never by this script) but WITHOUT `-p`. The initial prompt is the positional argument, exactly how
`rd wave <repo> '<prompt>'` hands work to a worker. Trust dialog: answered once with Enter. When
the done marker appears (or the screen is idle), `/exit` is sent. No wall-clock ceiling; the only
liveness rule is idle output (rules/agent-limits.md).
"""

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ANSI = re.compile(r"\x1b\[[0-9;?<>]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]")

CHILD_SCRIPT = r"""
source ~/.zsh/conf.d/claude.zsh >/dev/null 2>&1
key=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
base=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null)
[[ -n "$key" && -n "$base" ]] || { echo "IU credentials missing" >&2; exit 1; }
prompt=$(cat "$2")
exec env -u ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN="$key" ANTHROPIC_BASE_URL="$base" \
  claude --model haiku --dangerously-skip-permissions --strict-mcp-config --mcp-config "$1" \
  --settings '{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"1"}}' "$prompt"
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cwd", required=True)
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--mcp-config", required=True)
    ap.add_argument("--done-marker", required=True)
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--idle", type=float, default=60.0, help="seconds without output before /exit is sent")
    args = ap.parse_args()

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(args.cwd)
        os.environ.setdefault("TERM", "xterm-256color")
        os.execvp("zsh", ["zsh", "-c", CHILD_SCRIPT, "_", args.mcp_config, args.prompt_file])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 180, 0, 0))

    buf = b""
    last_output = time.time()
    trusted = exit_sent = False
    marker = args.done_marker.encode()
    marker_at: float | None = None
    status = 0
    while True:
        readable, _, _ = select.select([fd], [], [], 1.0)
        if readable:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            buf += data
            last_output = time.time()
            # The TUI repositions the cursor instead of printing spaces: compare with spaces and
            # ANSI stripped. The trust dialog (observed 2.1.308) puts the cursor on "No, exit" with
            # "Yes, I trust this folder" below it, so Enter alone would quit: move down first.
            plain = ANSI.sub("", buf[-8000:].decode("utf-8", "replace")).replace(" ", "").lower()
            if not trusted and ("trustthisfolder" in plain or "yes,iaccept" in plain):
                os.write(fd, b"\x1b[B")
                time.sleep(0.4)
                os.write(fd, b"\r")
                trusted = True
                buf += b"\n[probe: answered startup dialog with Down+Enter]\n"
            if marker_at is None and marker in buf:
                marker_at = time.time()
        done_wait = marker_at is not None and time.time() - marker_at > 4
        idle = time.time() - last_output > args.idle
        if (done_wait or idle) and not exit_sent:
            os.write(fd, b"/exit\r")
            exit_sent = True
            last_output = time.time()
        try:
            wpid, wstatus = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if wpid:
            status = wstatus
            break
        if exit_sent and time.time() - last_output > 20:  # /exit swallowed: ask politely, then stop
            os.kill(pid, signal.SIGINT)
            time.sleep(1)
            os.kill(pid, signal.SIGTERM)
            break

    with open(args.transcript, "wb") as f:
        f.write(buf)
    print(f"interactive probe finished: trusted={trusted} marker_seen={marker_at is not None} bytes={len(buf)}")
    return os.waitstatus_to_exitcode(status) if status else 0


if __name__ == "__main__":
    sys.exit(main())
