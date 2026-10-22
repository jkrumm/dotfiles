#!/usr/bin/env python3
"""Assemble docs/factory/report.html from the section files.

    python3 -I build.py            # write ../report.html
    python3 -I build.py --check    # report missing files/paths/assets, exit 1 if any

Stdlib only. Output is deterministic apart from the generation timestamp.
"""
import html
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent  # docs/factory
OUT = BASE / "report.html"
ASSETS = BASE / "report" / "assets"

# (id, label, path, title if the file has no usable h1)
SECTIONS = [
    ("s0", "", "report/00-reading-order.md"),
    ("s1", "", "report/01-verdict.md"),
    ("s1b", "", "report/01b-what-changes.md"),
    ("s2", "", "report/02-baseline.md"),
    ("s3", "3", "design/model.md"),
    ("s4", "4", "design/loops.md"),
    ("s4b", "4b", "report/04b-drawings.md"),
    ("s5", "", "report/05-decisions.md"),
    ("s6", "6", "design/argo.md"),
    ("s7", "7", "design/proof.md"),
    ("s8", "8", "report/08-panel.md"),
    ("s9", "9", "waves.md"),
    ("s10", "", "report/10-open-decisions.md"),
    ("s11", "", "report/11-faq.md"),
]
DEFAULT_TITLES = {"s8": "Panel review"}

PATH_RE = re.compile(
    r"^((?:evidence|adr|spikes|research|design|report|phase0)/[\w./-]*|waves\.md|BRIEF\.md|STATUS\.md)"
    r"(?::\d+(?:-\d+)?)?$"
)
PH_RE = re.compile(r"⟨[^⟩]*⟩")
SEP_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
LIST_RE = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
FENCE_RE = re.compile(r"^\s{0,3}(`{3,}|~{3,})\s*([\w+-]*)\s*$")
HR_RE = re.compile(r"^\s{0,3}([-*_])(\s*\1){2,}\s*$")
HEAD_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
ASSET_RE = re.compile(r"\{\{asset:([\w.-]+)\}\}")


def esc(s):
    return html.escape(s, quote=False)


def slug(s):
    s = re.sub(r"[`*_]", "", s).lower()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-") or "x"


def mark_placeholders(s):
    return PH_RE.sub(lambda m: f'<mark class="ph">{m.group(0)}</mark>', s)


def load_svg(name):
    p = ASSETS / f"{name}.svg"
    if not p.is_file():
        return None
    svg = p.read_text(encoding="utf-8")
    svg = re.sub(r"^\s*<\?xml.*?\?>", "", svg, flags=re.S)
    svg = re.sub(r"<!DOCTYPE[^>]*>", "", svg)
    svg = re.sub(r"^\s*(<!--.*?-->\s*)+", "", svg, flags=re.S).strip()

    def fix(m):
        tag = m.group(0)
        if "role=" not in tag:
            tag = tag[:-1] + ' role="img"' + ">"
        if "aria-label" not in tag and "aria-labelledby" not in tag and "<title" not in svg:
            tag = tag[:-1] + f' aria-label="{html.escape(name, quote=True)}">'
        return tag

    return re.sub(r"<svg\b[^>]*>", fix, svg, count=1)


class Renderer:
    def __init__(self, sec_id, src):
        self.sec = sec_id
        self.srcdir = src.parent
        self.h2 = []  # (id, text)
        self.ids = set()
        self.missing_paths = []
        self.missing_assets = []
        self.title = None

    # ---------- inline ----------
    def asset_html(self, name):
        svg = load_svg(name)
        if svg is None:
            if name not in self.missing_assets:
                self.missing_assets.append(name)
            return f'<div class="missing">Missing asset: report/assets/{esc(name)}.svg</div>'
        return f'<figure class="asset">{svg}</figure>'

    def code_html(self, raw, linkify):
        inner = f"<code>{mark_placeholders(esc(raw))}</code>"
        m = PATH_RE.match(raw.strip())
        if not m:
            return inner
        path = m.group(1)
        if (BASE / path).exists():
            if linkify:
                return f'<a class="pathlink" href="{html.escape(path, quote=True)}">{inner}</a>'
            return inner
        if "*" not in path and path not in self.missing_paths:
            self.missing_paths.append(path)
        return inner

    def link_url(self, url):
        if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I) or url.startswith("#"):
            return html.escape(url, quote=True), ' rel="noopener"' if url[:4] == "http" else ""
        target, _, frag = url.partition("#")
        resolved = (self.srcdir / target).resolve()
        try:
            rel = resolved.relative_to(BASE)
        except ValueError:
            return html.escape(url, quote=True), ""
        for sid, _, p in SECTIONS:
            if (BASE / p).resolve() == resolved and not frag:
                return f"#{sid}", ""
        return html.escape(str(rel) + ("#" + frag if frag else ""), quote=True), ""

    def inline(self, text):
        stash = []

        def put(kind, val):
            stash.append((kind, val))
            return f"\x00{len(stash) - 1}\x00"

        text = re.sub(r"(`+)(.+?)(?<!`)\1(?!`)", lambda m: put("code", m.group(2).strip("\n")), text)
        text = ASSET_RE.sub(lambda m: put("html", self.asset_html(m.group(1))), text)
        text = esc(text)

        def restore(s, linkify):
            def sub(m):
                kind, val = stash[int(m.group(1))]
                return self.code_html(val, linkify) if kind == "code" else val

            return re.sub(r"\x00(\d+)\x00", sub, s)

        def link(m):
            href, extra = self.link_url(m.group(2))
            return put("html", f'<a href="{href}"{extra}>{restore(m.group(1), False)}</a>')

        text = re.sub(r'\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)', link, text)
        text = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)", r"<strong>\1</strong>", text)
        text = re.sub(r"(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])", r"<em>\1</em>", text)
        text = re.sub(r"(?<![\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w])", r"<em>\1</em>", text)
        text = mark_placeholders(text)
        return restore(text, True)

    # ---------- blocks ----------
    def heading_id(self, text):
        base = f"{self.sec}-{slug(text)}"
        hid, n = base, 2
        while hid in self.ids:
            hid = f"{base}-{n}"
            n += 1
        self.ids.add(hid)
        return hid

    def render(self, md):
        lines = md.replace("\r\n", "\n").replace("\t", "    ").split("\n")
        return self.blocks(lines, top=True)

    def blocks(self, lines, top=False):
        out = []
        i = 0
        n = len(lines)
        while i < n:
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            m = FENCE_RE.match(line)
            if m:
                fence, lang = m.group(1), m.group(2)
                body = []
                i += 1
                while i < n and not re.match(rf"^\s{{0,3}}{re.escape(fence[0])}{{{len(fence)},}}\s*$", lines[i]):
                    body.append(lines[i])
                    i += 1
                i += 1
                cls = f' class="lang-{html.escape(lang, quote=True)}"' if lang else ""
                out.append(f"<pre><code{cls}>{mark_placeholders(esc(chr(10).join(body)))}</code></pre>")
                continue
            m = HEAD_RE.match(line)
            if m:
                out.append(self.heading(len(m.group(1)), m.group(2), top))
                i += 1
                continue
            if HR_RE.match(line) and not LIST_RE.match(line):
                out.append("<hr>")
                i += 1
                continue
            if "|" in line and i + 1 < n and SEP_RE.match(lines[i + 1]) and "-" in lines[i + 1]:
                j = i + 2
                while j < n and lines[j].strip() and "|" in lines[j]:
                    j += 1
                out.append(self.table(lines[i:j]))
                i = j
                continue
            if line.lstrip().startswith(">"):
                j = i
                quoted = []
                while j < n and lines[j].lstrip().startswith(">"):
                    quoted.append(re.sub(r"^\s*>\s?", "", lines[j]))
                    j += 1
                out.append(f"<blockquote>{self.blocks(quoted)}</blockquote>")
                i = j
                continue
            if LIST_RE.match(line):
                j = i
                chunk = []
                while j < n:
                    cur = lines[j]
                    if cur.strip():
                        if LIST_RE.match(cur) or cur.startswith("  "):
                            chunk.append(cur)
                            j += 1
                            continue
                        break
                    k = j + 1
                    while k < n and not lines[k].strip():
                        k += 1
                    if k < n and (LIST_RE.match(lines[k]) or lines[k].startswith("  ")) and not FENCE_RE.match(lines[k]):
                        j = k
                        continue
                    break
                out.append(self.list(chunk))
                i = j
                continue
            j = i
            para = []
            while j < n and lines[j].strip():
                if para and (
                    FENCE_RE.match(lines[j])
                    or HEAD_RE.match(lines[j])
                    or lines[j].lstrip().startswith(">")
                    or LIST_RE.match(lines[j])
                    or HR_RE.match(lines[j])
                ):
                    break
                para.append(lines[j].strip())
                j += 1
            joined = " ".join(para)
            if ASSET_RE.fullmatch(joined):
                out.append(self.asset_html(ASSET_RE.fullmatch(joined).group(1)))
            else:
                out.append(f"<p>{self.inline(joined)}</p>")
            i = j
        return "\n".join(out)

    def heading(self, level, text, top):
        if top and level == 1 and self.title is None:
            self.title = text
            return f'<h1 id="{self.sec}" class="sec-title">%%BADGE%%{self.inline(text)}</h1>'
        if level == 1:
            level = 2
        hid = self.heading_id(text)
        if level == 2:
            self.h2.append((hid, text))
        return f'<h{level} id="{hid}">{self.inline(text)}<a class="anchor" href="#{hid}" aria-label="Link to this heading">#</a></h{level}>'

    def split_row(self, row):
        row = row.strip()
        cells, cur, in_code = [], [], False
        i = 0
        while i < len(row):
            c = row[i]
            if c == "\\" and i + 1 < len(row) and row[i + 1] == "|":
                cur.append("|")
                i += 2
                continue
            if c == "`":
                in_code = not in_code
            if c == "|" and not in_code:
                cells.append("".join(cur))
                cur = []
            else:
                cur.append(c)
            i += 1
        cells.append("".join(cur))
        if cells and not cells[0].strip():
            cells = cells[1:]
        if cells and not cells[-1].strip():
            cells = cells[:-1]
        return [c.strip() for c in cells]

    def table(self, rows):
        head = self.split_row(rows[0])
        aligns = []
        for c in self.split_row(rows[1]):
            left, right = c.startswith(":"), c.endswith(":")
            aligns.append("center" if left and right else "right" if right else "left" if left else "")

        def cell(tag, text, k):
            a = aligns[k] if k < len(aligns) else ""
            style = f' style="text-align:{a}"' if a else ""
            return f"<{tag}{style}>{self.inline(text)}</{tag}>"

        out = ['<div class="tw"><table><thead><tr>']
        out += [cell("th", c, k) for k, c in enumerate(head)]
        out.append("</tr></thead><tbody>")
        for r in rows[2:]:
            cells = self.split_row(r)
            out.append("<tr>" + "".join(cell("td", c, k) for k, c in enumerate(cells)) + "</tr>")
        out.append("</tbody></table></div>")
        return "".join(out)

    def list(self, chunk):
        m = LIST_RE.match(chunk[0])
        base = len(m.group(1))
        ordered = m.group(2)[0].isdigit()
        items = []
        for line in chunk:
            lm = LIST_RE.match(line)
            if lm and len(lm.group(1)) <= base:
                items.append({"text": [lm.group(3)], "sub": [], "num": lm.group(2)})
            elif not items:
                continue
            elif items[-1]["sub"] or lm:
                items[-1]["sub"].append(line)
            elif line.strip():
                items[-1]["text"].append(line.strip())
            else:
                items[-1]["sub"].append(line)
        tag = "ol" if ordered else "ul"
        start = ""
        if ordered:
            num = int(re.match(r"\d+", items[0]["num"]).group(0))
            start = f' start="{num}"' if num != 1 else ""
        out = [f"<{tag}{start}>"]
        for it in items:
            body = self.inline(" ".join(it["text"]))
            sub = [s for s in it["sub"]]
            nested = ""
            if any(s.strip() for s in sub):
                first = next(s for s in sub if s.strip())
                if LIST_RE.match(first):
                    ind = min(len(s) - len(s.lstrip()) for s in sub if s.strip())
                    nested = self.list([s[ind:] if s.strip() else s for s in sub])
                else:
                    nested = self.blocks([s.strip() for s in sub])
            out.append(f"<li>{body}{nested}</li>")
        out.append(f"</{tag}>")
        return "".join(out)


CSS = r"""
:root{--bg:#1f1f23;--surface:#26262b;--border:#3a3a41;--text:#e4e4e7;--muted:#a1a1aa;--accent:#8ab4ff;--code:#2d2d33;--amber-bg:#4a3a0f;--amber-fg:#ffd36b;--amber-bd:#a07a14;color-scheme:dark}
@media (prefers-color-scheme:light){:root:not([data-theme]){--bg:#f2f2f5;--surface:#e9e9ee;--border:#d0d0d8;--text:#27272a;--muted:#62626c;--accent:#2f5bd0;--code:#e4e4ea;--amber-bg:#ffe08a;--amber-fg:#4f3300;--amber-bd:#d9a520;color-scheme:light}}
:root[data-theme=light]{--bg:#f2f2f5;--surface:#e9e9ee;--border:#d0d0d8;--text:#27272a;--muted:#62626c;--accent:#2f5bd0;--code:#e4e4ea;--amber-bg:#ffe08a;--amber-fg:#4f3300;--amber-bd:#d9a520;color-scheme:light}
:root[data-theme=dark]{color-scheme:dark}
*{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:12px}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
code,pre,kbd{font-family:"JetBrainsMono Nerd Font Mono","JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
code{background:var(--code);padding:.1em .35em;border-radius:3px;font-size:.88em}
pre{background:var(--code);border:1px solid var(--border);border-radius:6px;padding:10px 12px;overflow-x:auto;font-size:12.5px;line-height:1.45}
pre code{background:none;padding:0;font-size:inherit}
a{color:var(--accent)}
a.pathlink{text-decoration:none}a.pathlink:hover{text-decoration:underline}
header.top{padding:18px 24px 14px;border-bottom:1px solid var(--border);display:flex;flex-wrap:wrap;gap:6px 24px;align-items:flex-end;justify-content:space-between}
header.top h1{margin:0;font-size:24px;letter-spacing:-.01em}
header.top .meta{color:var(--muted);font-size:12.5px}
header.top .meta b{color:var(--text);font-weight:600}
header.top .meta .ph-count{background:var(--amber-bg);color:var(--amber-fg);border:1px solid var(--amber-bd);padding:0 6px;border-radius:3px}
button.btn{background:var(--surface);color:var(--text);border:1px solid var(--border);border-radius:5px;padding:3px 10px;font:inherit;font-size:12.5px;cursor:pointer}
.layout{display:grid;grid-template-columns:270px minmax(0,1fr);gap:0;align-items:start}
nav#toc{position:sticky;top:0;max-height:100vh;overflow-y:auto;padding:14px 12px 24px 20px;border-right:1px solid var(--border);font-size:13px}
nav#toc ol{list-style:none;margin:0;padding:0}
nav#toc li{margin:0}
nav#toc a{display:block;color:var(--muted);text-decoration:none;padding:1px 0;line-height:1.35}
nav#toc a:hover{color:var(--text)}
nav#toc > ol > li > a{color:var(--text);font-weight:600;margin-top:9px}
nav#toc ol ol{padding-left:12px}
nav#toc .tocbar{display:flex;gap:8px;align-items:center;margin-bottom:4px}
#toc-toggle{display:none}
main{padding:12px 28px 80px;min-width:0;max-width:1180px}
section.sec{padding-top:6px;border-top:1px solid var(--border);margin-top:28px}
section.sec:first-child{border-top:0;margin-top:0}
main p,main ul,main ol,main blockquote,main h2,main h3,main h4,main h5,main h6{max-width:78ch}
h1.sec-title{font-size:26px;margin:16px 0 8px;letter-spacing:-.01em}
h1 .badge{display:inline-block;font-size:12px;vertical-align:middle;color:var(--muted);border:1px solid var(--border);border-radius:4px;padding:0 6px;margin-right:8px;font-weight:600}
h2{font-size:19px;margin:26px 0 6px;padding-bottom:3px;border-bottom:1px solid var(--border)}
h3{font-size:16px;margin:20px 0 4px}
h4,h5,h6{font-size:14px;margin:16px 0 2px;color:var(--muted)}
.anchor{opacity:0;margin-left:6px;text-decoration:none;font-weight:400;color:var(--muted)}
:is(h2,h3,h4,h5,h6):hover .anchor{opacity:1}
p{margin:.5em 0}
ul,ol{margin:.4em 0;padding-left:1.5em}
li{margin:.15em 0}li>ul,li>ol{margin:.1em 0}
blockquote{margin:.7em 0;padding:2px 14px;border-left:3px solid var(--border);color:var(--muted)}
hr{border:0;border-top:1px solid var(--border);margin:20px 0}
.tw{width:100%;overflow-x:auto;margin:.7em 0}
table{border-collapse:collapse;width:100%;font-size:13px;line-height:1.4}
th,td{border:1px solid var(--border);padding:4px 8px;vertical-align:top;text-align:left}
th{background:var(--surface);position:sticky;top:0}
tbody tr:nth-child(even){background:color-mix(in srgb,var(--surface) 55%,transparent)}
figure.asset{margin:14px 0;padding:10px;background:var(--surface);border:1px solid var(--border);border-radius:6px;overflow-x:auto}
figure.asset svg{max-width:100%;height:auto;display:block;margin:0 auto}
mark.ph{background:var(--amber-bg);color:var(--amber-fg);border:1px solid var(--amber-bd);border-radius:3px;padding:0 3px;font-weight:600}
mark.ph code{background:none;color:inherit}
.missing{border:2px dashed var(--amber-bd);background:var(--amber-bg);color:var(--amber-fg);padding:10px 14px;border-radius:6px;margin:12px 0;font-weight:600}
@media (max-width:900px){
.layout{display:block}
nav#toc{position:static;max-height:none;border-right:0;border-bottom:1px solid var(--border);padding:10px 16px}
#toc-toggle{display:inline-block}
nav#toc ol.toc-list{display:none}
nav#toc.open ol.toc-list{display:block}
main{padding:8px 14px 60px}
header.top{padding:14px 14px 10px}
body{font-size:14.5px}
}
@media print{
:root,:root[data-theme]{--bg:#fff;--surface:#f4f4f6;--border:#c8c8d0;--text:#111;--muted:#444;--accent:#111;--code:#f0f0f3;--amber-bg:#ffe9a8;--amber-fg:#3d2800;--amber-bd:#b08000;color-scheme:light}
body{font-size:10.5pt}
nav#toc,button.btn,.anchor{display:none!important}
.layout{display:block}
main{max-width:none;padding:0}
a{color:inherit;text-decoration:none}
pre{white-space:pre-wrap;overflow:visible}
.tw{overflow:visible}
th{position:static}
tr,figure,pre,blockquote{break-inside:avoid}
h1,h2,h3{break-after:avoid}
section.sec{break-before:page;border-top:0;margin-top:0}
section.sec:first-child{break-before:auto}
}
"""

JS = r"""
(function(){
var r=document.documentElement,k='factory-theme';
function eff(){var t=r.getAttribute('data-theme');if(t)return t;return matchMedia('(prefers-color-scheme: light)').matches?'light':'dark'}
function label(){var b=document.getElementById('theme-toggle');if(b)b.textContent=eff()==='dark'?'Light theme':'Dark theme'}
document.getElementById('theme-toggle').addEventListener('click',function(){var n=eff()==='dark'?'light':'dark';r.setAttribute('data-theme',n);try{localStorage.setItem(k,n)}catch(e){}label()});
label();
var toc=document.getElementById('toc'),tt=document.getElementById('toc-toggle');
tt.addEventListener('click',function(){var o=toc.classList.toggle('open');tt.setAttribute('aria-expanded',o)});
toc.addEventListener('click',function(e){if(e.target.tagName==='A')toc.classList.remove('open')});
})();
"""

HEAD_JS = "try{var t=localStorage.getItem('factory-theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t)}catch(e){}"


def git_sha():
    try:
        r = subprocess.run(
            ["git", "-C", str(BASE), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
        return r.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def build():
    missing_files, missing_paths, missing_assets = [], [], []
    toc, bodies = [], []
    ph_total = 0
    for sid, label, rel in SECTIONS:
        src = BASE / rel
        r = Renderer(sid, src)
        if not src.is_file():
            missing_files.append(rel)
            title = DEFAULT_TITLES.get(sid, rel)
            body = (
                f'<h1 id="{sid}" class="sec-title"><span class="badge">{esc(label)}</span>{esc(title)}</h1>'
                f'<div class="missing">Section not written yet: {esc(rel)}</div>'
            )
            toc.append((sid, f"{label}. {title}" if label else title, []))
            bodies.append(f'<section class="sec" aria-labelledby="{sid}">{body}</section>')
            continue
        md = src.read_text(encoding="utf-8")
        ph_total += len(PH_RE.findall(md))
        body = r.render(md)
        title = r.title or rel
        badge = "" if re.match(r"^\d+b?\.", title) or not label else f'<span class="badge">§{esc(label)}</span>'
        body = body.replace("%%BADGE%%", badge, 1)
        toc.append((sid, re.sub(r"[`*]", "", title), r.h2))
        bodies.append(f'<section class="sec" aria-labelledby="{sid}">{body}</section>')
        missing_paths += [(rel, p) for p in r.missing_paths]
        missing_assets += [(rel, a) for a in r.missing_assets]

    toc_html = ['<ol class="toc-list">']
    for sid, title, h2s in toc:
        toc_html.append(f'<li><a href="#{sid}">{esc(title)}</a>')
        if h2s:
            toc_html.append("<ol>")
            for hid, text in h2s:
                plain = re.sub(r"[`*]", "", text)
                toc_html.append(f'<li><a href="#{hid}">{esc(plain)}</a></li>')
            toc_html.append("</ol>")
        toc_html.append("</li>")
    toc_html.append("</ol>")

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Factory design — 2026-10-22</title>
<script>{HEAD_JS}</script>
<style>{CSS}</style>
</head>
<body>
<header class="top">
<div>
<h1>Factory design — 2026-10-22</h1>
<div class="meta">Generated <b>{now}</b> · dotfiles <b>{esc(git_sha())}</b> · <span class="ph-count">{ph_total} open placeholders ⟨…⟩</span></div>
<div class="meta">Comments go through <code>rv</code>.</div>
</div>
<button class="btn" id="theme-toggle" type="button" aria-label="Toggle colour theme">Theme</button>
</header>
<div class="layout">
<nav id="toc" aria-label="Table of contents">
<div class="tocbar"><button class="btn" id="toc-toggle" type="button" aria-expanded="false">Contents</button></div>
{"".join(toc_html)}
</nav>
<main>
{chr(10).join(bodies)}
</main>
</div>
<script>{JS}</script>
</body>
</html>
"""
    return doc, missing_files, missing_paths, missing_assets, ph_total


def main():
    check = "--check" in sys.argv[1:]
    doc, mf, mp, ma, ph = build()
    problems = False
    if mf:
        problems = True
        print("Missing section files:")
        for f in mf:
            print(f"  {f}")
    if mp:
        problems = True
        print("Backticked factory paths that do not exist:")
        for src, p in mp:
            print(f"  {p}  (in {src})")
    if ma:
        problems = True
        print("Missing assets:")
        for src, a in ma:
            print(f"  report/assets/{a}.svg  (in {src})")
    if check:
        if not problems:
            print(f"OK — all sections, paths and assets resolve ({ph} open placeholders).")
        sys.exit(1 if problems else 0)
    OUT.write_text(doc, encoding="utf-8")
    print(f"wrote {OUT} ({len(doc.encode('utf-8'))} bytes, {ph} placeholders)")


if __name__ == "__main__":
    main()
