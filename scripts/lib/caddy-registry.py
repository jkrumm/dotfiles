#!/usr/bin/env python3
"""Extract the local dev-app registry from the Caddyfile.

Emits one TSV line per `<name>.test` reverse-proxy site block, sorted by name:

    <name>\t<port>\t<host_rewrite 0|1>

This exists so that `config/Caddyfile` is the SINGLE registry of dev apps.
Before it there were two lists — the Caddyfile's `*.test` blocks and
`~/.config/caddy-tailnet.ports` — and they drifted silently: a new app got a
local `.test` door immediately and a tailnet door only if you remembered the
second file. Now the second file records exceptions only (see the opt-out file
header written by scripts/caddy-tailnet.sh).

The Caddyfile is parsed by handing it to `caddy adapt --adapter caddyfile` and
walking the resulting route JSON — never by regexing the Caddyfile body. Caddy
is the only thing that agrees with Caddy about what a Caddyfile means, and the
body defeats regex in three separate ways already present in the live file: the
`metabase.iu-aws.de` block (a non-`.test` vhost that must not be picked up),
snippet imports (`import local`), and the `header_up Host` variant inside
`fpp.test`'s proxy block.

Safety: the machine-local include (`import .../Caddyfile.d/*.caddy`) is stripped
before adapting, because on the dev host that file holds a live Cloudflare API
token. It must never enter the parse path, the adapted JSON, or any output.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

DEFAULT_CADDYFILE = "/opt/homebrew/etc/Caddyfile"

# The machine-local include. Matched loosely (any path ending in Caddyfile.d/...)
# so a relocated brew prefix or a relative import is caught just the same.
MACHINE_LOCAL_INCLUDE = re.compile(r"^\s*import\s+\S*Caddyfile\.d/")

FORBIDDEN_TOKEN = "Caddyfile.d"

# A single DNS label: what `<name>.<DEV_DOMAIN>` can actually be built from.
LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")

# Loopback dial forms we accept for a local dev server.
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "[::1]", "::1"}

# Blocks that are *expected* not to be apps and must not be reported as skipped.
# The `http://*.test` HTTPS redirect is a real, permanent block in the tracked
# Caddyfile; reporting it on every single run would train the reader to ignore
# the skip report — which is the one channel that says a real app went missing.
EXPECTED_NON_APPS = {"*.test"}


class ExtractError(RuntimeError):
    """Fatal, operator-facing. Never carries the Cloudflare token."""


# --------------------------------------------------------------------------
# source preparation
# --------------------------------------------------------------------------


def strip_comments(text: str) -> str:
    """Blank out Caddyfile comments, preserving line count and structure.

    Caddy's lexer treats `#` as a comment only when it *begins* a token, and
    not inside a quoted string. Replicated here so the guards below reason
    about real directives rather than prose — the live Caddyfile documents the
    machine-local include in a comment directly above the include itself, so a
    naive substring guard dies on every run against a perfectly good file.
    """
    out_lines = []
    for line in text.splitlines():
        quote = None
        escaped = False
        prev_was_boundary = True
        cut = None
        for i, ch in enumerate(line):
            if escaped:
                escaped = False
                prev_was_boundary = False
                continue
            if ch == "\\":
                escaped = True
                prev_was_boundary = False
                continue
            if quote:
                if ch == quote:
                    quote = None
                prev_was_boundary = False
                continue
            if ch in ('"', "`"):
                quote = ch
                prev_was_boundary = False
                continue
            if ch == "#" and prev_was_boundary:
                cut = i
                break
            prev_was_boundary = ch.isspace()
        out_lines.append(line if cut is None else line[:cut])
    return "\n".join(out_lines)


def _import_argument(line: str) -> str | None:
    m = re.match(r"^\s*import\s+(.+?)\s*$", line)
    if not m:
        return None
    parts = m.group(1).split()
    arg = parts[0] if parts else ""
    if len(arg) >= 2 and arg[0] == arg[-1] and arg[0] in ('"', "`"):
        arg = arg[1:-1]
    return arg


def prepare_source(raw: str) -> str:
    """Strip the machine-local include, then prove nothing dangerous remains.

    Two guards, both fatal:

    1. No `Caddyfile.d` reference survives outside comments. If one does, the
       strip regex missed a form of the include and adapting would pull the
       token-bearing file into the parse path.
    2. No *other* file import survives. We adapt from `/dev/stdin`, so Caddy
       resolves relative imports against `/dev` rather than the Caddyfile's own
       directory — a surviving file import would silently resolve to nothing
       and the app table would come back short with no error at all. Snippet
       imports (`import local`) are unaffected: they resolve inside the
       document and are explicitly allowed.
    """
    kept = [ln for ln in raw.splitlines() if not MACHINE_LOCAL_INCLUDE.match(ln)]
    stripped = "\n".join(kept) + "\n"

    directives = strip_comments(stripped)

    if FORBIDDEN_TOKEN in directives:
        bad = [
            i + 1
            for i, ln in enumerate(directives.splitlines())
            if FORBIDDEN_TOKEN in ln
        ]
        raise ExtractError(
            f"refusing to adapt: {FORBIDDEN_TOKEN!r} still present in directive "
            f"text at line(s) {bad} after stripping the machine-local include. "
            "That file holds a live Cloudflare API token and must never reach "
            "the parser. Fix MACHINE_LOCAL_INCLUDE to cover this form."
        )

    for i, ln in enumerate(directives.splitlines(), start=1):
        arg = _import_argument(ln)
        if arg is None:
            continue
        if "/" in arg or "*" in arg:
            raise ExtractError(
                f"refusing to adapt: unsupported file import at line {i} "
                "(argument contains '/' or '*'). Adapting happens from stdin, "
                "so relative file imports resolve against the wrong directory "
                "and are silently dropped — the app table would come back "
                "short with no error. Snippet imports are fine; a new file "
                "import must be handled explicitly here."
            )

    return stripped


# --------------------------------------------------------------------------
# adapt
# --------------------------------------------------------------------------


def adapt(source: str, caddy_bin: str) -> dict:
    """Adapt the Caddyfile to JSON via `/dev/stdin`.

    Why stdin and not a temp file: the source sits next to a secret-bearing
    include, and a temp file means a second on-disk copy of production config
    with a lifetime, a cleanup path that can be skipped on crash, and umask
    questions. stdin has none of that, and costs nothing in fidelity (verified
    byte-identical JSON both ways). It costs nothing in import resolution
    either — a temp file in $TMPDIR gets relative imports just as wrong as
    /dev does, which is what guard #2 above exists to catch regardless.

    Caddy's stderr IS forwarded on failure, deliberately. It quotes the
    offending source line, and by this point the two guards have proven the
    only thing being adapted is the tracked, token-free `config/Caddyfile`.
    Swallowing it would cost a line number on every syntax error to protect a
    secret that provably is not in this buffer.
    """
    try:
        proc = subprocess.run(
            [caddy_bin, "adapt", "--adapter", "caddyfile", "--config", "/dev/stdin"],
            input=source.encode(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        raise ExtractError(f"{caddy_bin!r} not found on PATH")

    if proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip()
        raise ExtractError(
            f"caddy adapt failed (exit {proc.returncode}):\n{detail}"
        )

    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise ExtractError(f"caddy adapt produced unparseable JSON: {exc.msg}")


# --------------------------------------------------------------------------
# route walking
# --------------------------------------------------------------------------


def iter_handlers(handlers):
    """Yield every handler, descending through Caddy's `subroute` wrapping.

    A bare `name.test { reverse_proxy ... }` block adapts to
    route -> handle[subroute] -> routes[] -> handle[reverse_proxy], and a block
    using `handle`/`route` nests further. Recursion keeps this independent of
    how deep the author nested things.
    """
    for h in handlers or []:
        if not isinstance(h, dict):
            continue
        yield h
        for sub in h.get("routes") or []:
            if isinstance(sub, dict):
                yield from iter_handlers(sub.get("handle"))


def match_hosts(route: dict) -> list[str]:
    hosts = []
    for m in route.get("match") or []:
        if isinstance(m, dict):
            hosts.extend(m.get("host") or [])
    return hosts


def dial_port(dial: str) -> int | None:
    """Port from `localhost:PORT` / `127.0.0.1:PORT` / `[::1]:PORT`."""
    if not isinstance(dial, str):
        return None
    host, sep, port = dial.rpartition(":")
    if not sep or not port.isdigit():
        return None
    if host.strip("[]") not in {h.strip("[]") for h in LOOPBACK_HOSTS}:
        return None
    n = int(port)
    return n if 1 <= n <= 65535 else None


def host_rewrite_port(handler: dict) -> int | None:
    """Port from a `header_up Host localhost:PORT` on this reverse_proxy."""
    values = (
        (handler.get("headers") or {}).get("request", {}).get("set", {}).get("Host")
    )
    if not values:
        return None
    return dial_port(values[0])


def extract(config: dict) -> tuple[list[tuple[str, int, int]], list[str]]:
    """Walk every route; return (rows, skipped).

    Everything here is deliberately defensive — an unrecognised block is
    SKIPPED and reported, never guessed at. A wrong port in a generated proxy
    is worse than a missing door.
    """
    apps: dict[str, tuple[int, int]] = {}
    skipped: list[str] = []

    servers = ((config.get("apps") or {}).get("http") or {}).get("servers") or {}
    for server in servers.values():
        if not isinstance(server, dict):
            continue
        for route in server.get("routes") or []:
            if not isinstance(route, dict):
                continue

            hosts = match_hosts(route)
            if not hosts:
                continue
            if len(hosts) > 1:
                skipped.append(f"{hosts[0]}: multi-host match ({len(hosts)} hosts)")
                continue

            host = hosts[0]
            if host in EXPECTED_NON_APPS:
                continue
            if not host.endswith(".test"):
                continue  # metabase.iu-aws.de and friends: not a local dev app

            name = host[: -len(".test")]
            if not LABEL.match(name):
                skipped.append(f"{host}: not a single DNS label")
                continue

            proxies = [
                h
                for h in iter_handlers(route.get("handle"))
                if h.get("handler") == "reverse_proxy"
            ]
            if not proxies:
                skipped.append(f"{host}: no reverse_proxy upstream")
                continue
            if len(proxies) > 1:
                skipped.append(f"{host}: {len(proxies)} reverse_proxy handlers")
                continue

            proxy = proxies[0]
            upstreams = proxy.get("upstreams") or []
            ports = [p for p in (dial_port(u.get("dial")) for u in upstreams) if p]
            if not ports:
                skipped.append(f"{host}: no loopback upstream port")
                continue
            if len(set(ports)) > 1:
                skipped.append(f"{host}: {len(set(ports))} distinct upstream ports")
                continue

            port = ports[0]
            rewrite = 1 if host_rewrite_port(proxy) == port else 0

            if name in apps and apps[name] != (port, rewrite):
                skipped.append(f"{host}: duplicate block disagrees with earlier one")
                continue
            apps[name] = (port, rewrite)

    rows = sorted((n, p, r) for n, (p, r) in apps.items())
    return rows, sorted(skipped)


# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract the .test dev-app registry.")
    ap.add_argument("--caddyfile", default=DEFAULT_CADDYFILE)
    ap.add_argument("--caddy-bin", default="caddy")
    ap.add_argument(
        "--quiet", action="store_true", help="suppress the skipped-block report"
    )
    args = ap.parse_args()

    try:
        with open(args.caddyfile, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        print(f"error: cannot read {args.caddyfile}: {exc.strerror}", file=sys.stderr)
        return 2

    try:
        rows, skipped = extract(adapt(prepare_source(raw), args.caddy_bin))
    except ExtractError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if skipped and not args.quiet:
        for s in skipped:
            print(f"skipped {s}", file=sys.stderr)

    # Refuse to emit an empty registry. Without this, a future Caddyfile
    # restructure that breaks the walker would return zero rows and the
    # generator consuming it would silently tear down every dev door rather
    # than failing.
    if not rows:
        print(
            "error: no .test dev apps found — refusing to emit an empty registry",
            file=sys.stderr,
        )
        return 2

    sys.stdout.write("".join(f"{n}\t{p}\t{r}\n" for n, p, r in rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
