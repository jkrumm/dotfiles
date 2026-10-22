#!/usr/bin/env python3
"""Shell-command normaliser for the toil accounting (evidence/toil).

Question it serves: turn raw shell commands (owner history lines, agent Bash tool inputs)
into structure-only *patterns* -- `command + subcommand`, every argument replaced by a
placeholder or elided -- so they can be counted without storing or leaking the raw text.

Definition keys from DEFINITIONS.md: none (toil has no baseline metric of its own).

Inputs: a command string. Outputs: `normalize(cmd)` -> list of (pattern, head) tuples, one
per pipeline stage that carries meaning; `classify(pattern)` -> coarse kind.

What is stripped (never reaches an output):
  * env assignments (`FOO=bar cmd`), including every secret-looking one;
  * every argument, flag value, path, URL, quoted string, heredoc body, redirect target;
  * pipeline filters (`| head`, `| grep`, `| jq`) and trivial producers feeding a command;
  * command words that are not on the allow-list become `<other-cmd>`;
  * with mask=True (IU-context history) script names, make targets and package scripts
    that are not generic become `<target>` / `<other>`.

How to run (self-test only; the module is imported by toil.py and scan_transcripts.py):
  python3 -I cmdnorm.py --selftest
"""

import re
import sys

# --------------------------------------------------------------------------- vocab

GLUE = {
    "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "true", "false", ":",
    "test", "[", "[[", "read", "<assign>", "<loop>", "<fn>", "wait", "trap", "exit",
    "alias", "unalias", "hash", "umask", "ulimit", "echo", "printf", "pwd", "return",
    "declare", "local", "typeset", "shift", "eval", "break", "continue", "disown", "jobs", "fg", "bg",
}
INSPECT = {
    "ls", "ll", "la", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "find", "wc",
    "sort", "uniq", "cut", "tr", "awk", "jq", "yq", "stat", "file", "which", "type",
    "whence", "date", "basename", "dirname", "realpath", "readlink", "tee", "column", "nl",
    "less", "more", "tree", "bat", "diff", "cmp", "id", "whoami", "hostname", "uname",
    "sw_vers", "env", "printenv", "mktemp", "fd", "xxd", "od", "strings", "comm", "paste",
    "tput", "stty", "git-ls", "sed", "xargs",
}
NAV = {"cd", "ls", "pwd", "j", "z", "pushd", "popd", "clear", "ll", "la"}

# pipeline stages dropped when they follow a meaningful producer
FILTERS = {
    "head", "tail", "grep", "egrep", "fgrep", "rg", "awk", "sed", "sort", "uniq", "wc", "cut",
    "tr", "jq", "yq", "column", "nl", "less", "more", "tee", "cat", "echo", "printf", "base64",
    "shasum", "md5", "md5sum", "xxd", "od", "fold", "fmt", "paste", "comm", "join", "bat",
    "tac", "rev", "strings", "cmp", "diff", "xargs", "sha256sum", "pbcopy", "tput", "less",
}
# pipeline producers that carry no meaning when a real consumer follows
TRIVIAL_PRODUCERS = {"echo", "printf", "cat", "yes", "head", "tail", "grep", "rg", "sed", "awk"}

WRAPPERS = {
    "env", "command", "builtin", "exec", "nohup", "time", "nice", "caffeinate", "setsid",
    "stdbuf", "unbuffer", "ionice", "chrt", "doas", "noglob", "arch",
}
KEYWORDS_STRIP = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}", "(", ")", "time"}
KEYWORDS_DROP = {"done", "fi", "esac", "in", "for", "select", "case", "function", "coproc"}

SSH_ALIASES = {"mini", "homelab", "vps", "iumac", "macbook", "iu", "dev"}

# commands with sub-verbs: cmd -> (depth, vocab or None=any lowercase word)
GIT_SUBS = set(
    "add am apply archive bisect blame branch bundle cat-file check-ignore checkout "
    "cherry-pick clean clone commit commit-tree config count-objects describe diff "
    "diff-tree difftool fetch filter-branch filter-repo for-each-ref format-patch fsck gc "
    "grep hash-object init log ls-files ls-remote ls-tree maintenance merge merge-base mv "
    "name-rev notes patch-id pull push range-diff read-tree rebase reflog remote repack reset "
    "restore revert rev-list rev-parse rm shortlog show show-ref sparse-checkout stash status "
    "submodule switch symbolic-ref tag update-index update-ref verify-commit whatchanged "
    "worktree write-tree lfs".split()
)
GIT_SUB2 = {"stash", "remote", "worktree", "submodule", "notes", "sparse-checkout", "lfs", "bisect"}
GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
GIT_SALIENT = {
    "push": ["--force-with-lease", "--force", "-f", "--delete", "--tags"],
    "reset": ["--hard", "--soft", "--mixed"],
    "commit": ["--amend", "--no-verify", "--allow-empty"],
    "rebase": ["--continue", "--abort", "--skip", "-i", "--onto"],
    "checkout": ["-b"],
    "switch": ["-c"],
    "clean": ["-fd", "-fdx", "-f", "-xdf"],
    "branch": ["-D", "-d", "-m"],
    "merge": ["--abort", "--ff-only", "--no-ff", "--squash"],
    "cherry-pick": ["--continue", "--abort"],
    "stash": [],
    "diff": ["--stat", "--name-only", "--cached", "--staged", "--check"],
    "log": ["--oneline"],
}

DEPTH1_VOCAB = {
    "brew": set("install upgrade update outdated list info services cleanup doctor search uninstall bundle tap untap pin unpin leaves deps link unlink fetch autoremove config --prefix --cellar casks".split()),
    "launchctl": set("list kickstart print bootstrap bootout load unload enable disable kill start stop remove submit blame managerpid asuser dumpstate print-disabled".split()),
    "systemctl": set("status restart start stop enable disable reload daemon-reload is-active is-enabled list-units list-timers cat show mask unmask edit reset-failed".split()),
    "tailscale": set("status ip ssh serve funnel up down ping cert set netcheck whois file switch lock login logout version dns debug".split()),
    "cargo": set("build run test check clippy fmt install add remove update doc bench clean publish tree".split()),
    "rustup": set("update toolchain default component target show".split()),
    "uv": set("run sync add remove lock pip venv tool python init build publish".split()),
    "pip": set("install uninstall list freeze show".split()),
    "pip3": set("install uninstall list freeze show".split()),
    "desk": set(),
    "jobrun": set(),
    "hl": set("lsd ls copy sync move presign mount umount cat size rcat lsf".split()),
    "secrets-run": set("run read export".split()),
    "limactl": set("list start stop shell create delete".split()),
    "colima": set("start stop status list delete".split()),
    "defaults": set("read write delete".split()),
    "diskutil": set("list info mount unmount eject apfs repairVolume".split()),
    "pmset": set(),
    "tmutil": set("listlocalsnapshots deletelocalsnapshots status".split()),
    "security": set("find-generic-password add-generic-password delete-generic-password unlock-keychain list-keychains".split()),
    "softwareupdate": set(),
    "networksetup": set(),
    "scutil": set(),
    "sqlite3": set(),
    "npx": None, "bunx": None,
}
# CLIs with noun/verb grammar: the verb after a known noun is kept (`gh pr create`, `op item get`)
NOUNS = {
    "gh": set("pr issue run repo workflow release api auth browse gist label secret variable cache search status extension alias project codespace ruleset config".split()),
    "glab": set("mr issue ci pipeline repo api auth release variable job config user label snippet schedule".split()),
    "docker": set("compose container image volume network system buildx context builder manifest stack node service swarm plugin".split()),
    "op": set("item vault account document user group connect plugin service-account events-api environment".split()),
    "herdr": set("pane tab workspace agent worktree notification session integration config machine channel api server".split()),
    "docker-compose": set(),
}
# service/operation CLIs: both tokens are API vocabulary
SERVICE_CLIS = {"aws", "kubectl", "helm", "gcloud", "terraform"}
# CLIs whose first sub-word is a verb from a (possibly open) vocabulary; later words are arguments
VERB_VOCAB = {
    "claude": set("mcp config update doctor install setup-token migrate-installer plugin agents auth".split()),
    "codex": set("exec login logout resume apply mcp".split()),
    "opencode": set("run serve attach session models auth export import stats upgrade web github".split()),
    "hermes": set("chat model moa fallback worktree browser secrets egress cron gateway setup skills tools doctor status logs sessions".split()),
    "agw": set("dispatch check review update-pr triage decide prose jobs status wait cancel steer routing policy health".split()),
    "warden": set("dispatch run status list merge abort revert close retry reinvestigate adopt pause resume help".split()),
    "bd": None,
    "rd": set("repos work wave fan merge close reap agents read say".split()),
    "ask-human": None,
    "ask-human.sh": None,
    "fallow": None,
    "browser-use": None,
    "imgcli": None,
    "cloudflared": None,
}
OWNER_CMDS = {
    "c", "cs", "cf", "ca", "cdf", "cdp", "cap", "cx", "cxa", "astra", "oc", "j", "desk",
    "reset", "clear", "sz", "gback", "npmplease", "caddy-reload", "opbackup", "homelab",
    "vps", "zh", "start-iu-fe", "sync-iu-db", "rd", "agw", "warden", "herdr", "hermes",
    "jobrun", "hl", "secrets-run", "ask-human", "ask-human.sh", "imgcli", "fallow", "bd",
    "bu", "browser", "browser-use", "browser-use-tui", "browseruse", "cua-driver", "keyprobe",
    "jobs-grade", "tinycast", "modelpick", "z", "repos", "work", "agents", "mo", "basalt-ui",
}
PKG = {"npm", "pnpm", "yarn", "bun"}
PKG_SUBS = set(
    "install i add remove rm uninstall update up upgrade outdated test run run-script x exec "
    "link unlink init create publish pack audit ci cache why ls list pm build dlx".split()
)
GENERIC_SCRIPTS = set(
    "dev build test lint typecheck check format start preview install ci clean deploy up down "
    "logs verify doctor setup help all fmt tidy".split()
)
INTERPRETERS = {"bash", "sh", "zsh", "dash", "python", "python3", "node", "deno", "ruby", "perl", "tsx", "ts-node"}

KNOWN = (
    {"git"}
) | set(DEPTH1_VOCAB) | set(NOUNS) | SERVICE_CLIS | set(VERB_VOCAB) | OWNER_CMDS | PKG | INTERPRETERS | GLUE | INSPECT | FILTERS | WRAPPERS | set(
    """
    make gmake cmake ninja cc gcc clang tsc eslint biome prettier vitest jest playwright pytest ruff mypy
    go rustc swift swiftc xcodebuild xcrun java mvn gradle dotnet npx bunx pnpx corepack fnm nvm volta
    curl wget http https nc ncat ping ping6 dig nslookup host traceroute mtr netstat ss lsof arp ifconfig route
    ssh scp sftp rsync rclone sshpass ssh-keygen ssh-add ssh-copy-id mosh
    ps pgrep pkill kill killall top htop df du free vm_stat iostat uptime sysctl log
    mkdir rmdir rm mv cp ln touch chmod chown chgrp open pbpaste pbcopy say afplay screencapture
    tar zip unzip gzip gunzip bzip2 xz 7z base64 shasum md5 openssl gpg age
    sleep watch timeout seq yes tmux screen zellij
    sudo su plutil osascript mdfind mdls xattr codesign spctl systemextensionsctl tccutil
    sqlite3 psql mysql redis-cli clickhouse clickhouse-client duckdb
    ffmpeg ffprobe convert magick sips
    patch sed awk gawk gsed
    flock lockf logger crontab at
    nvm pyenv rbenv asdf direnv mise
    expo eas wrangler vercel netlify flyctl railway tauri
    rustfmt cargo-clippy
    ollama llm
    tsx
    renovate shellcheck oxfmt oxlint man col pnpx dseditgroup sysadminctl fdesetup xattr
    uvx journalctl mount mountpoint caddy nproc dpkg setopt getfattr getent lsblk lsattr iconutil
    qlmanage pg_isready iptables iptables-save ip lscpu compgen compare mailgw gh-runner
    textutil pdftotext qpdf
    """.split()
)

BENIGN_NONZERO_HEADS = {
    "grep", "egrep", "fgrep", "rg", "test", "[", "[[", "diff", "cmp", "pgrep", "which",
    "type", "command", "lsof", "fd", "comm", "stat", "ls",
}
BENIGN_NONZERO_PATTERNS = {
    "git diff", "git merge-base", "git cat-file", "git show-ref", "git ls-remote",
    "git rev-parse", "git symbolic-ref", "git config", "git diff --check", "git diff --cached",
    "git diff --name-only", "git diff --stat", "git branch", "git log", "git status",
}

# development aid: set to a list to collect command words that map to <other-cmd> (never stored)
COLLECT = None

# --------------------------------------------------------------------------- tokenizer

_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=")
_WORD_STOP = set(" \t\n;&|<>()")


class Word:
    __slots__ = ("text", "quoted", "subst")

    def __init__(self, text="", quoted=False, subst=False):
        self.text = text
        self.quoted = quoted
        self.subst = subst


def _skip_heredoc(s, i):
    """s[i:] starts just after `<<`; return index after the heredoc terminator line."""
    n = len(s)
    j = i
    strip = False
    if j < n and s[j] == "-":
        strip = True
        j += 1
    while j < n and s[j] in " \t":
        j += 1
    delim = ""
    if j < n and s[j] in "'\"":
        q = s[j]
        k = s.find(q, j + 1)
        if k < 0:
            return n
        delim = s[j + 1:k]
        j = k + 1
    else:
        k = j
        while k < n and s[k] not in " \t\n;&|<>()":
            k += 1
        delim = s[j:k]
        j = k
    return j, delim, strip


def _heredoc_body_end(s, start, delim, strip):
    """Index after the terminator line of a heredoc whose body begins at `start`."""
    if not delim:
        return len(s)
    pat = re.compile(r"^" + (r"\t*" if strip else "") + re.escape(delim) + r"[ \t]*$", re.M)
    m = pat.search(s, start)
    if not m:
        return len(s)
    return m.end()


def _skip_balanced(s, i):
    """s[i] == '('; return index after the matching ')' (quote/heredoc aware)."""
    n = len(s)
    depth = 0
    j = i
    while j < n:
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "'":
            k = s.find("'", j + 1)
            j = n if k < 0 else k + 1
            continue
        if c == '"':
            j += 1
            while j < n and s[j] != '"':
                if s[j] == "\\":
                    j += 1
                elif s[j] == "$" and s[j + 1:j + 2] == "(":
                    j = _skip_balanced(s, j + 1) - 1
                j += 1
            j += 1
            continue
        if c == "<" and s[j:j + 2] == "<<" and s[j:j + 3] != "<<<":
            res = _skip_heredoc(s, j + 2)
            if isinstance(res, int):
                return n
            k, delim, strip = res
            nl = s.find("\n", k)
            if nl < 0:
                return n
            j = _heredoc_body_end(s, nl + 1, delim, strip)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def _read_dquote(s, i):
    """s[i] == '"'; return (text, new_i, subst)."""
    n = len(s)
    out = []
    subst = False
    j = i + 1
    while j < n and s[j] != '"':
        c = s[j]
        if c == "\\" and j + 1 < n:
            nxt = s[j + 1]
            if nxt == "\n":
                j += 2
                continue
            out.append(nxt if nxt in '"\\$`' else c + nxt)
            j += 2
            continue
        if c == "$" and s[j + 1:j + 2] == "(":
            j = _skip_balanced(s, j + 1)
            out.append("\x00S")
            subst = True
            continue
        if c == "`":
            k = s.find("`", j + 1)
            j = n if k < 0 else k + 1
            out.append("\x00S")
            subst = True
            continue
        if c == "$" and s[j + 1:j + 2] == "{":
            k = s.find("}", j + 1)
            j = n if k < 0 else k + 1
            out.append("\x00V")
            continue
        if c == "$" and j + 1 < n and (s[j + 1].isalnum() or s[j + 1] in "_@*#?"):
            k = j + 1
            while k < n and (s[k].isalnum() or s[k] == "_"):
                k += 1
            out.append("\x00V")
            j = max(k, j + 2)
            continue
        out.append(c)
        j += 1
    return "".join(out), min(j + 1, n), subst


def _read_word(s, i):
    n = len(s)
    out = []
    quoted = False
    subst = False
    j = i
    while j < n:
        c = s[j]
        if c in _WORD_STOP:
            break
        if c == "\\":
            if j + 1 < n and s[j + 1] == "\n":
                j += 2
                continue
            if j + 1 < n:
                out.append(s[j + 1])
            j += 2
            continue
        if c == "'":
            k = s.find("'", j + 1)
            end = n if k < 0 else k
            out.append(s[j + 1:end])
            quoted = True
            j = end + 1
            continue
        if c == '"':
            text, j, sub = _read_dquote(s, j)
            out.append(text)
            quoted = True
            subst = subst or sub
            continue
        if c == "$" and s[j + 1:j + 2] == "(":
            j = _skip_balanced(s, j + 1)
            out.append("\x00S")
            subst = True
            continue
        if c == "`":
            k = s.find("`", j + 1)
            j = n if k < 0 else k + 1
            out.append("\x00S")
            subst = True
            continue
        if c == "$" and s[j + 1:j + 2] == "{":
            k = s.find("}", j + 1)
            j = n if k < 0 else k + 1
            out.append("\x00V")
            continue
        if c == "$" and j + 1 < n and (s[j + 1].isalnum() or s[j + 1] in "_@*#?"):
            k = j + 1
            while k < n and (s[k].isalnum() or s[k] == "_"):
                k += 1
            out.append("\x00V")
            j = max(k, j + 2)
            continue
        out.append(c)
        j += 1
    return Word("".join(out), quoted, subst), j


def tokenize(s):
    """Return [(words, op, heredoc)] segments split on unquoted && || ; | & newline."""
    n = len(s)
    segs = []
    words = []
    heredoc = False
    pending = []
    i = 0

    def end_seg(op):
        nonlocal words, heredoc
        if words or op in ("&&", "||"):
            segs.append((words, op, heredoc))
        words = []
        heredoc = False

    while i < n:
        c = s[i]
        if c in " \t":
            i += 1
            continue
        if c == "\n":
            end_seg("\n")
            i += 1
            for delim, strip in pending:
                i = _heredoc_body_end(s, i, delim, strip)
                nl = s.find("\n", i)
                i = n if nl < 0 else nl + 1
            pending = []
            continue
        if c == "#" and not words or (c == "#" and False):
            k = s.find("\n", i)
            i = n if k < 0 else k
            continue
        if c == "\\" and s[i + 1:i + 2] == "\n":
            i += 2
            continue
        if c == ";":
            end_seg(";")
            i += 2 if s[i + 1:i + 2] == ";" else 1
            continue
        if c == "&":
            if s[i + 1:i + 2] == "&":
                end_seg("&&")
                i += 2
                continue
            if s[i + 1:i + 2] == ">":
                i += 2
                if s[i:i + 1] == ">":
                    i += 1
                while i < n and s[i] in " \t":
                    i += 1
                _, i = _read_word(s, i)
                continue
            end_seg("&")
            i += 1
            continue
        if c == "|":
            if s[i + 1:i + 2] == "|":
                end_seg("||")
                i += 2
                continue
            end_seg("|")
            i += 2 if s[i + 1:i + 2] == "&" else 1
            continue
        if c in "()":
            end_seg("(")
            i += 1
            continue
        if c in "<>":
            # redirection: optional fd digits already consumed as a word -> drop it
            if words and words[-1].text.isdigit() and not words[-1].quoted and i > 0 and s[i - 1].isdigit():
                words.pop()
            if s.startswith("<<<", i):
                i += 3
                while i < n and s[i] in " \t":
                    i += 1
                _, i = _read_word(s, i)
                continue
            if s.startswith("<<", i):
                res = _skip_heredoc(s, i + 2)
                if isinstance(res, int):
                    i = res
                    continue
                i, delim, strip = res
                pending.append((delim, strip))
                heredoc = True
                continue
            op = c
            i += 1
            if s[i:i + 1] == c and c == ">":
                i += 1
            if s[i:i + 1] in ("&", "|") and c == ">":
                i += 1
            elif s[i:i + 1] == "&" and c == "<":
                i += 1
            while i < n and s[i] in " \t":
                i += 1
            _, i = _read_word(s, i)
            continue
        w, i2 = _read_word(s, i)
        if i2 == i:
            i += 1
            continue
        i = i2
        words.append(w)
    end_seg("\n")
    return segs


# --------------------------------------------------------------------------- patterns


def _basename(p):
    return p.rsplit("/", 1)[-1]


def _is_word(t):
    return bool(re.fullmatch(r"[a-z][a-z0-9_-]{0,28}", t)) and "\x00" not in t


def _is_flag(t):
    return t.startswith("-") and len(t) > 1 and not re.fullmatch(r"-?\d+(\.\d+)?", t)


def _host_class(h):
    h = h.split("@")[-1]
    return h if h in SSH_ALIASES else "<host>"


def _url_class(args):
    for a in args:
        if "://" in a or re.match(r"^[A-Za-z0-9.-]+(:\d+)?(/|$)", a):
            low = a.lower()
            if "localhost" in low or "127.0.0.1" in low or "[::1]" in low or low.startswith(":"):
                return "<local>"
            return "<remote>"
    return "<remote>"


def _script_name(t, mask):
    b = _basename(t)
    if mask or not re.fullmatch(r"[A-Za-z0-9._-]{1,48}", b):
        return "<other>"
    return b


def _strip_leading(words):
    """Drop shell keywords, return (words, dropped_segment_flag, loop_flag)."""
    i = 0
    while i < len(words) and words[i].text in KEYWORDS_STRIP and not words[i].quoted:
        i += 1
    ws = words[i:]
    if not ws:
        return ws, True, False
    first = ws[0].text
    if first in KEYWORDS_DROP and not ws[0].quoted:
        return ws, True, first in ("for", "select")
    return ws, False, False


def _positional(args, value_flags=()):
    """Positional tokens of args, skipping flags (and values of known value flags)."""
    out = []
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a == "--":
            continue
        if _is_flag(a):
            if a in value_flags:
                skip = True
            continue
        out.append(a)
    return out


def _seg_patterns(words, heredoc, mask, depth):
    """Patterns (list of (pattern, head)) for one segment."""
    words, drop, loop = _strip_leading(words)
    if drop:
        return [("<loop>", "<loop>")] if loop else []
    if not words:
        return []
    i = 0
    n = len(words)
    while i < n and _ASSIGN.match(words[i].text):
        i += 1
    if i == n:
        return [("<assign>", "<assign>")]
    # wrappers
    sudo = False
    xargs = False
    while i < n:
        w = words[i].text
        b = _basename(w)
        if b == "sudo":
            sudo = True
            i += 1
            while i < n and _is_flag(words[i].text):
                if words[i].text in ("-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t"):
                    i += 1
                i += 1
            continue
        if b in WRAPPERS:
            i += 1
            while i < n and (_is_flag(words[i].text) or _ASSIGN.match(words[i].text)):
                i += 1
            continue
        if b == "timeout":
            i += 1
            while i < n and _is_flag(words[i].text):
                i += 1
            if i < n and re.fullmatch(r"\d+[smhd]?", words[i].text):
                i += 1
            continue
        if b == "xargs":
            xargs = True
            i += 1
            while i < n and _is_flag(words[i].text):
                if words[i].text in ("-n", "-I", "-P", "-L", "-d", "-s"):
                    i += 1
                i += 1
            continue
        break
    if i >= n:
        return [("sudo" if sudo else "xargs" if xargs else "<assign>", "sudo")]
    pats = _command_pattern(words[i:], heredoc, mask, depth)
    prefix = ("sudo " if sudo else "") + ("xargs " if xargs else "")
    if prefix:
        pats = [(prefix + p, h) for p, h in pats]
    return pats


def _command_pattern(words, heredoc, mask, depth):
    w0 = words[0]
    cmd = w0.text
    args = [w.text for w in words[1:]]
    if w0.subst or "\x00" in cmd:
        return [("<subst-cmd>", "<subst-cmd>")]
    is_path = "/" in cmd or cmd.startswith("~")
    base = _basename(cmd) if is_path else cmd
    if is_path and re.search(r"\.(sh|bash|zsh|py|ts|js|mjs|rb|pl)$", base):
        return [("script " + _script_name(base, mask), "script")]
    if is_path and base not in KNOWN and not cmd.startswith(("/usr/", "/bin/", "/opt/", "/sbin/")):
        return [("script " + _script_name(base, mask), "script")]
    cmd = base
    # keep a literal case: make/ls etc. are lower-case; others as-is
    low = cmd.lower() if cmd.isupper() else cmd
    if re.fullmatch(r"python3?\.\d+", low):
        low = "python3"

    if low == "cd" or low in ("pushd", "popd"):
        return [(low + " <path>", low)]
    if low == "sleep":
        return [("sleep <n>", "sleep")]
    if low == "ssh":
        return _ssh(args, mask, depth)
    if low in ("scp", "rsync", "sftp"):
        return [(low + " " + ("<host>" if any(":" in a and "/" not in a.split(":")[0] for a in args) else "<local>"), low)]
    if low in INTERPRETERS:
        return _interp(low, args, heredoc, mask, depth)
    if low == "git":
        return [(_git(args), "git")]
    if low in PKG:
        return [(_pkg(low, args, mask), low)]
    if low in ("make", "gmake"):
        return [(_make(args, mask), "make")]
    if low in ("curl", "wget", "http", "https"):
        return [("curl " + _url_class(_positional(args, {"-X", "-H", "-d", "-o", "-u", "--data", "--header", "--request", "--output", "-w", "--max-time", "-m", "-A", "--retry"})), "curl")]
    if low == "rm":
        flags = "".join(sorted(set("".join(a.lstrip("-") for a in args if _is_flag(a) and not a.startswith("--")))))
        return [("rm -rf <path>" if ("r" in flags or "R" in flags) and "f" in flags else "rm -r <path>" if ("r" in flags or "R" in flags) else "rm <path>", "rm")]
    if low == "sed":
        return [("sed -i" if any(a == "-i" or a.startswith("-i") and not a.startswith("--") for a in args) else "sed", "sed")]
    if low in ("open",):
        return [("open <target>", "open")]
    if low in NOUNS or low in SERVICE_CLIS:
        return [(_depth2(low, args), low)]
    if low in VERB_VOCAB:
        return [(_verb(low, args), low)]
    if low in DEPTH1_VOCAB:
        vocab = DEPTH1_VOCAB[low]
        if vocab is None:
            pos = _positional(args)
            return [(low + (" " + re.sub(r"@.*$", "", pos[0]) if pos and re.fullmatch(r"[@a-z0-9._/-]{1,40}", pos[0]) and not mask else ""), low)]
        pos = _positional(args)
        sub = pos[0] if pos and pos[0] in vocab else ""
        return [((low + " " + sub).strip(), low)]
    if low in OWNER_CMDS or low in KNOWN:
        return [(low, low)]
    if COLLECT is not None:
        COLLECT.append(low)
    return [("<other-cmd>", "<other-cmd>")]


def _first_word(tokens):
    for t in tokens:
        if _is_flag(t):
            continue
        return t if _is_word(t) else ""
    return ""


def _depth2(cmd, args):
    pos = _positional(args, {"--profile", "--region", "--account", "--vault", "-R", "--repo", "-n", "--namespace", "--context", "-c", "-H", "--host", "--output"})
    out = [cmd]
    if not pos or not _is_word(pos[0]):
        return cmd
    out.append(pos[0])
    if cmd in SERVICE_CLIS or pos[0] in NOUNS.get(cmd, ()):
        if len(pos) > 1 and _is_word(pos[1]):
            out.append(pos[1])
    return " ".join(out)


def _verb(cmd, args):
    """CLI with a verb vocabulary; a long positional is a prompt, not a verb."""
    vocab = VERB_VOCAB[cmd]
    flags = [a for a in args if _is_flag(a)]
    pos = _positional(args, {"--model", "-m", "--effort", "--resume", "-r", "-w", "--worktree", "--add-dir", "--output-format", "--permission-mode", "--setting-sources", "--allowed-tools", "--mcp-config", "--profile", "-p", "--provider", "-t", "--in", "--repo", "--tier", "--why", "--brief-file", "--model-id"})
    out = cmd
    if cmd == "claude":
        for f in ("--resume", "-r", "--continue", "-c", "--bg", "-p", "--print", "-w", "--worktree"):
            if f in flags or f in args:
                out += " " + {"-r": "--resume", "-c": "--continue", "-p": "--print", "-w": "--worktree"}.get(f, f)
                break
    if pos:
        t = pos[0]
        if vocab is None:
            if _is_word(t):
                return out + " " + t
        elif t in vocab:
            return out + " " + t
        elif cmd == "claude" and len(t) >= 60:
            return "claude <prompt>"
    return out


def _git(args):
    pos = []
    skip = False
    flags = []
    for a in args:
        if skip:
            skip = False
            continue
        if a in GIT_VALUE_FLAGS:
            skip = True
            continue
        if _is_flag(a):
            flags.append(a)
            if not pos:
                continue
        if not _is_flag(a):
            pos.append(a)
        else:
            flags.append(a)
        if len(pos) >= 2:
            break
    sub = pos[0] if pos and pos[0] in GIT_SUBS else ""
    if not sub:
        return "git"
    out = "git " + sub
    if sub in GIT_SUB2 and len(pos) > 1 and _is_word(pos[1]):
        out += " " + pos[1]
    for flag in GIT_SALIENT.get(sub, []):
        if any(a == flag or (flag.startswith("--") and a.startswith(flag + "=")) for a in args):
            out += " " + flag
            break
    return out


def _make(args, mask):
    pos = []
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a in ("-C", "-f", "-j", "-l", "-I", "-o", "-W", "--directory", "--file"):
            skip = True
            continue
        if _is_flag(a) or "=" in a:
            continue
        pos.append(a)
    if not pos or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:-]*", pos[0]):
        return "make"
    t = pos[0]
    if mask and t not in GENERIC_SCRIPTS:
        return "make <target>"
    return "make " + t


def _pkg(cmd, args, mask):
    pos = _positional(args, {"--prefix", "-w", "--workspace", "--cwd", "-c", "--config", "-C", "--dir", "--filter", "-F"})
    if not pos:
        return cmd
    sub = pos[0]
    if sub in ("run", "run-script"):
        if len(pos) > 1:
            s = pos[1]
            if re.fullmatch(r"[a-z][a-z0-9:_-]{0,30}", s) and not (mask and s not in GENERIC_SCRIPTS):
                return f"{cmd} run {s}"
            return f"{cmd} run <script>"
        return f"{cmd} run"
    if sub in ("x", "dlx", "exec"):
        return f"{cmd} {sub}"
    if sub in PKG_SUBS:
        return f"{cmd} {sub}"
    if re.search(r"\.(ts|js|mjs|tsx|jsx)$", sub) or "/" in sub:
        return f"{cmd} <script>"
    if re.fullmatch(r"[a-z][a-z0-9:_-]{0,30}", sub):
        if mask and sub not in GENERIC_SCRIPTS:
            return f"{cmd} run <script>"
        return f"{cmd} run {sub}"
    return cmd


def _interp(cmd, args, heredoc, mask, depth):
    if cmd in ("bash", "sh", "zsh", "dash"):
        for k, a in enumerate(args):
            if a == "-c" or (a.startswith("-") and not a.startswith("--") and "c" in a[1:] and len(a) <= 4):
                if k + 1 < len(args) and depth < 3:
                    inner = normalize(args[k + 1], mask=mask, _depth=depth + 1)
                    return inner or [(cmd + " -c", cmd)]
                return [(cmd + " -c", cmd)]
        pos = _positional(args)
        if heredoc and not pos:
            return [(cmd + " <heredoc>", cmd)]
        if not pos:
            return [(cmd + " <stdin>", cmd)] if heredoc else [(cmd, cmd)]
        return [(f"{cmd} {_script_name(pos[0], mask)}", cmd)]
    if cmd in ("python", "python3"):
        if "-c" in args:
            return [(cmd.replace("python3", "python3") + " -c", "python3")]
        if "-m" in args:
            k = args.index("-m")
            mod = args[k + 1] if k + 1 < len(args) else ""
            return [("python3 -m " + (re.sub(r"[^a-z0-9_.]", "", mod.lower())[:24] if not mask else "<mod>"), "python3")]
        if "-" in args or (heredoc and not _positional(args)):
            return [("python3 <heredoc>", "python3")]
        pos = _positional(args)
        if pos:
            return [("python3 " + _script_name(pos[0], mask), "python3")]
        return [("python3", "python3")]
    if cmd in ("node", "deno", "tsx", "ts-node", "ruby", "perl"):
        if any(a in ("-e", "-p", "--eval", "-pe", "-ne") for a in args):
            return [(f"{cmd} -e", cmd)]
        if heredoc and not _positional(args):
            return [(f"{cmd} <heredoc>", cmd)]
        pos = _positional(args)
        if pos:
            return [(f"{cmd} {_script_name(pos[0], mask)}", cmd)]
        return [(cmd, cmd)]
    return [(cmd, cmd)]


def _ssh(args, mask, depth):
    pos = []
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a in ("-p", "-i", "-o", "-l", "-L", "-R", "-D", "-J", "-F", "-b", "-c", "-E", "-S", "-W"):
            skip = True
            continue
        if _is_flag(a):
            continue
        pos.append(a)
    if not pos:
        return [("ssh", "ssh")]
    host = _host_class(pos[0])
    if len(pos) == 1:
        return [(f"ssh {host}", "ssh")]
    remote = " ".join(pos[1:])
    if depth >= 3:
        return [(f"ssh {host}", "ssh")]
    inner = normalize(remote, mask=mask, _depth=depth + 1)
    inner = [(p, h) for p, h in inner if p not in ("<assign>",)]
    if not inner:
        return [(f"ssh {host}", "ssh")]
    return [(f"ssh {host}: {p}", h) for p, h in inner]


def _pipeline_filter(stages):
    """stages: list of lists of (pattern, head). Drop filter stages after a producer."""
    if len(stages) == 1:
        return stages[0]
    meaningful = []
    for k, st in enumerate(stages):
        if not st:
            continue
        head = st[0][1]
        if st[0][0].startswith("ssh "):
            meaningful.append(st)
            continue
        if head in FILTERS:
            continue
        if k < len(stages) - 1 and head in TRIVIAL_PRODUCERS:
            continue
        meaningful.append(st)
    if not meaningful:
        for st in stages:
            if st:
                return st
        return []
    out = []
    for st in meaningful:
        out.extend(st)
    return out


_LOOP_KW = re.compile(r"(?:^|[;&|(\n{]|\bdo\b)\s*(?:until|while|for)\b")
_SLEEP_IN = re.compile(r"\bsleep\s+[0-9$]")


def normalize(cmd, mask=False, _depth=0):
    """Ordered [(pattern, head)] for one shell command string; never raises."""
    try:
        segs = tokenize(cmd)
    except Exception:
        return [("<unparsed>", "<unparsed>")]
    out = []
    if _depth == 0 and _LOOP_KW.search(cmd) and _SLEEP_IN.search(cmd):
        out.append(("<poll-loop>", "<poll-loop>"))
    pipeline = []
    for words, op, heredoc in segs:
        try:
            pats = _seg_patterns(words, heredoc, mask, _depth) if words else []
        except Exception:
            pats = [("<unparsed>", "<unparsed>")]
        pipeline.append(pats)
        if op != "|":
            out.extend(_pipeline_filter(pipeline))
            pipeline = []
    if pipeline:
        out.extend(_pipeline_filter(pipeline))
    return out


# --------------------------------------------------------------------------- classify


def head_of(pattern):
    p = pattern
    if p.startswith("ssh ") and ": " in p:
        p = p.split(": ", 1)[1]
    p = re.sub(r"^(sudo |xargs )+", "", p)
    return p.split(" ", 1)[0]


def is_glue(pattern):
    return head_of(pattern) in GLUE


def is_inspect(pattern):
    h = head_of(pattern)
    return h in INSPECT and pattern != "sed -i"


GENERIC_PATTERNS = {
    "python3 <heredoc>", "python3 -c", "python3", "python3 <stdin>", "node -e", "node", "node <heredoc>",
    "perl -e", "bun <script>", "bun run <script>", "uv run", "bash", "bash <heredoc>", "bash <stdin>",
    "sh", "sh <heredoc>", "sh <stdin>", "zsh", "sed", "sed -i", "cat", "tail", "head", "sqlite3", "curl <local>",
    "curl <remote>", "bunx", "npx", "xargs",
}


def is_specific(pattern):
    """An action-level pattern (`bun test`, `git push`) as opposed to a tool-level one (`python3 <heredoc>`)."""
    return not is_noise(pattern) and pattern not in GENERIC_PATTERNS and not pattern.endswith(("<other>", "<script>"))


def is_noise(pattern):
    """Glue or read-only inspection: excluded from recipes and from ranked work lists."""
    return is_glue(pattern) or is_inspect(pattern) or pattern in ("<other-cmd>", "<subst-cmd>", "<unparsed>")


_KIND = [
    ("vcs", {"git", "gh", "glab"}),
    ("build/check", {"make", "gmake", "bun", "npm", "pnpm", "yarn", "npx", "bunx", "cargo", "uv", "pip", "pip3", "pytest", "tsc", "eslint", "biome", "prettier", "vitest", "jest", "playwright", "ruff", "mypy", "go", "swift", "xcodebuild", "mise", "fnm", "tauri"}),
    ("agent-orchestration", {"rd", "agw", "warden", "herdr", "hermes", "claude", "codex", "opencode", "bd", "jobrun", "ask-human", "ask-human.sh", "c", "cs", "cf", "ca", "cdf", "cdp", "cap", "cx", "cxa", "astra", "oc", "desk", "fallow", "bu", "browser", "browser-use"}),
    ("secrets", {"op", "secrets-run", "security", "age", "gpg", "ssh-keygen"}),
    ("host-ops", {"launchctl", "systemctl", "docker", "docker-compose", "kubectl", "helm", "ps", "pgrep", "pkill", "kill", "killall", "lsof", "df", "du", "top", "htop", "brew", "defaults", "diskutil", "sysctl", "pmset", "caddy-reload", "limactl", "colima", "log", "vm_stat", "systemextensionsctl", "tccutil", "tmutil", "plutil", "osascript", "sudo", "crontab", "journalctl", "terraform", "aws", "gcloud", "cloudflared"}),
    ("network", {"curl", "wget", "http", "https", "nc", "ping", "dig", "nslookup", "host", "tailscale", "ssh", "scp", "rsync", "rclone", "hl", "homelab", "vps", "mosh", "sftp", "traceroute", "mtr", "netstat"}),
    ("files", {"mkdir", "rmdir", "rm", "mv", "cp", "ln", "touch", "chmod", "chown", "tar", "zip", "unzip", "gzip", "open", "pbpaste", "sed", "script"}),
    ("scripting", {"python3", "python", "node", "bash", "sh", "zsh", "deno", "ruby", "perl", "tsx", "jq"}),
    ("waiting", {"sleep", "watch", "timeout", "<poll-loop>"}),
    ("terminal", {"reset", "clear", "j", "z", "sz", "tmux", "screen", "zellij"}),
]


def classify(pattern):
    h = head_of(pattern)
    if h in GLUE and h not in ("cd", "pushd", "popd"):
        return "glue"
    if h in ("cd", "pushd", "popd"):
        return "navigation"
    if h in INSPECT and pattern != "sed -i":
        return "inspect"
    if pattern.startswith("ssh ") and ": " in pattern:
        return classify(pattern.split(": ", 1)[1])
    for kind, heads in _KIND:
        if h in heads:
            return kind
    return "other"


def is_benign_nonzero(pattern_list):
    """True if a non-zero exit of this call is normal (grep no-match, test, diff...)."""
    for p in reversed(pattern_list):
        if is_glue(p) and head_of(p) not in ("test", "[", "[["):
            continue
        return head_of(p) in BENIGN_NONZERO_HEADS or p in BENIGN_NONZERO_PATTERNS or any(p.startswith(b + " ") for b in BENIGN_NONZERO_PATTERNS)
    return False


# --------------------------------------------------------------------------- self-test

_CASES = [
    ("git status --short | head", ["git status"]),
    ("cd ~/SourceRoot/dotfiles && git add -A && git commit -m \"fix: don't break\" && git push", ["cd <path>", "git add", "git commit", "git push"]),
    ("git commit -m \"$(cat <<'EOF'\nfix: don't do x\nEOF\n)\" && git push --force-with-lease", ["git commit", "git push --force-with-lease"]),
    ("ROOT_PW=$(op read 'op://x/y/z' --account a) ssh mini \"echo '$ROOT_PW' | sudo -S -v && cd ~/x && make caddy-dns-build\"", ["ssh mini: sudo", "ssh mini: cd <path>", "ssh mini: make caddy-dns-build"]),
    ("FOO=bar BAZ=qux bun run dev", ["bun run dev"]),
    ("npm install && npm run build", ["npm install", "npm run build"]),
    ("sleep 30 && rd agents", ["sleep <n>", "rd agents"]),
    ("make -C ~/SourceRoot/dotfiles check", ["make check"]),
    ("aws sso login --profile aws.X.Y", ["aws sso login"]),
    ("gh pr create --title \"x\" --body \"y\"", ["gh pr create"]),
    ("python3 - <<'EOF'\nimport os\nprint('don't')\nEOF", ["python3 <heredoc>"]),
    ("cat <<'EOF' > /tmp/x.sh\n#!/bin/bash\necho hi\nEOF\nbash /tmp/x.sh", ["cat", "bash x.sh"]),
    ("curl -s http://localhost:8080/health | jq .", ["curl <local>"]),
    ("for f in *.md; do echo $f; done", ["<loop>", "echo"]),
    ("op item get foo --vault bar --fields x", ["op item get"]),
    ("docker compose up -d", ["docker compose up"]),
    ("sudo launchctl kickstart -k system/x", ["sudo launchctl kickstart"]),
    ("ls -la | grep foo", ["ls"]),
    ("echo hi | ssh mini 'cat > f'", ["ssh mini: cat"]),
    ("rg -n foo src/ || true", ["rg", "true"]),
    ("git -C ~/x log --oneline -5", ["git log --oneline"]),
    ("bun test 2>&1 | tail -20", ["bun test"]),
    ("reset", ["reset"]),
    ("j dot", ["<other-cmd>"] if "j" not in KNOWN else ["j"]),
    ("export TOKEN=abc123 && curl -H \"Authorization: Bearer $TOKEN\" https://api.example.com/x", ["export", "curl <remote>"]),
    ("git stash && git pull --rebase && git stash pop", ["git stash", "git pull", "git stash pop"]),
    ("xargs -I{} rm {}", ["xargs rm <path>"]),
    ("sed -i '' 's/a/b/' file", ["sed -i"]),
    ("sh -c 'git fetch && git rebase origin/main'", ["git fetch", "git rebase"]),
    ("claude \"" + "x" * 80 + "\" --model sonnet", ["claude <prompt>"]),
    ("claude --resume 0f3e-aaaa --model opus", ["claude --resume"]),
    ("rd wave dotfiles 'do the thing'", ["rd wave"]),
    ("warden run dotfiles <<'EOF'\nbrief text\nEOF", ["warden run"]),
    ("herdr pane read w1:p2 --lines 40", ["herdr pane read"]),
    ("aws ecs update-service --cluster a --service b", ["aws ecs update-service"]),
    ("glab mr view 123 --web", ["glab mr view"]),
    ("op item create --vault v --category login - < /tmp/x.json", ["op item create"]),
    ("export USAGE_LANE=wave", ["export"]),
    ("until curl -sf localhost:1/h; do sleep 2; done; bun test", ["<poll-loop>", "curl <local>", "sleep <n>", "bun test"]),
    ("bun dev", ["bun run dev"]),
    ("bun run dev", ["bun run dev"]),
]


def selftest():
    bad = 0
    for cmd, want in _CASES:
        got = [p for p, _ in normalize(cmd)]
        if got != want:
            bad += 1
            print("FAIL", repr(cmd[:70]), "\n   got ", got, "\n   want", want)
    print("selftest", "FAILED" if bad else "ok", f"({len(_CASES) - bad}/{len(_CASES)})")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(__doc__)
