#!/usr/bin/env python3
"""Lines-of-code counter for the spike. "code" = lines that are not blank, not comment-only and not
inside a docstring; the SQL schema string in option A counts as code (it is the data model).

Usage: loc.py   (prints JSON: per file, and per top-level definition for the two option files)
"""
import ast
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GROUPS = {
    "option_a": ["option_a_ledger/flow_a.py", "option_a_ledger/status_a.py"],
    "option_b": ["option_b_dbos/flow_b.py", "option_b_dbos/status_b.py"],
    "shared_fixtures": ["common/world.py", "common/stub_api.py", "common/episode.py"],
    "harness": ["harness/killtest.py", "harness/crashloop.py", "harness/report_tables.py", "harness/loc.py"],
}


def classify(path: Path) -> dict:
    src = path.read_text()
    lines = src.splitlines()
    tree = ast.parse(src)
    doc: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) and isinstance(body[0].value.value, str):
                doc.update(range(body[0].lineno, body[0].end_lineno + 1))
    kind = {}
    for i, ln in enumerate(lines, 1):
        s = ln.strip()
        kind[i] = "blank" if not s else "doc" if i in doc else "comment" if s.startswith("#") else "code"
    return {"lines": lines, "kind": kind, "tree": tree}


def count(path: Path) -> dict:
    k = classify(path)["kind"]
    return {"total": len(k), "code": sum(v == "code" for v in k.values()), "comment": sum(v == "comment" for v in k.values()),
            "docstring": sum(v == "doc" for v in k.values()), "blank": sum(v == "blank" for v in k.values())}


def per_definition(path: Path) -> dict:
    c = classify(path)
    out = {}
    for node in c["tree"].body:
        if isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.Assign)):
            name = node.name if hasattr(node, "name") else getattr(node.targets[0], "id", "?")
            start = (node.decorator_list[0].lineno if getattr(node, "decorator_list", None) else node.lineno)
            out[name] = sum(1 for i in range(start, node.end_lineno + 1) if c["kind"][i] == "code")
    return out


if __name__ == "__main__":
    res = {}
    for group, files in GROUPS.items():
        res[group] = {"files": {f: count(ROOT / f) for f in files}}
        res[group]["code"] = sum(v["code"] for v in res[group]["files"].values())
        res[group]["total"] = sum(v["total"] for v in res[group]["files"].values())
    res["by_definition"] = {f: per_definition(ROOT / f) for f in ("option_a_ledger/flow_a.py", "option_b_dbos/flow_b.py")}
    json.dump(res, sys.stdout, indent=1)
