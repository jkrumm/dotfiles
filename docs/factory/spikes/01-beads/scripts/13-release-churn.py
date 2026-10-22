#!/usr/bin/env python3
"""Spike 1, step 7: release and pin churn from the real release metadata (GitHub API dumps saved by 01-install.sh
and the metadata fetched during the spike). Output: results/release-churn.json.
Inputs: $SPIKE/meta/beads-releases.json, dolt-releases.json, npm-beads-bd.json (public API responses)."""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import SPIKE, save  # noqa: E402

rel = json.load(open(f"{SPIKE}/meta/beads-releases.json"))
dolt = json.load(open(f"{SPIKE}/meta/dolt-releases.json"))
npm = json.load(open(f"{SPIKE}/meta/npm-beads-bd.json"))
rows = sorted(({"tag": r["tag_name"], "date": r["published_at"][:10], "prerelease": r["prerelease"]} for r in rel), key=lambda x: x["date"])
stable = [r for r in rows if not r["prerelease"]]
per_month = collections.Counter(r["date"][:7] for r in rows)
since_1_0 = [r for r in rows if r["date"] >= "2026-04-03"]
out = {
    "beads": {
        "latest_stable": stable[-1], "latest_any": rows[-1],
        "tags_in_api_page": len(rows), "stable_tags": len(stable),
        "stable_tags_since_v1_0_0": sum(1 for r in stable if r["date"] >= "2026-04-03"),
        "tags_since_v1_0_0_incl_rc": len(since_1_0),
        "tags_per_month": dict(sorted(per_month.items())),
        "incident": {"v1.2.1": next(r for r in rows if r["tag"] == "v1.2.1"), "v1.2.2": next(r for r in rows if r["tag"] == "v1.2.2"),
                     "github_marks_v1_2_1_prerelease": next(r for r in rows if r["tag"] == "v1.2.1")["prerelease"],
                     "npm_published_1_2_1": npm["time"]["1.2.1"], "npm_published_1_2_2": npm["time"]["1.2.2"],
                     "npm_latest_tag_now": npm["dist-tags"]["latest"]},
        "schema_versions_seen": {"v1.1.x/v1.2.2": 53, "v1.2.1 (accidental)": 65, "v1.3.0/v1.3.1": 66},
    },
    "dolt": {"pinned_by_beads": "2.2.0",
             "pinned_release_date": next(r["published_at"][:10] for r in dolt if r["tag_name"] == "v2.2.0"),
             "latest_stable": max(({"tag": r["tag_name"], "date": r["published_at"][:10]} for r in dolt if not r["prerelease"]), key=lambda x: x["date"]),
             "minor_versions_published_after_pin": sorted({r["tag_name"].rsplit(".", 1)[0] for r in dolt if r["published_at"] > "2026-07-15T17:42:00Z" and r["tag_name"].startswith("v2.")}),
             "release_created_out_of_order": "v1.88.2 was created 2026-08-17, after v2.2.4 and v2.3.0 (beads docs: releases/latest can move backwards)",
             "homebrew_beads_formula_depends_on_unpinned_dolt": True},
    "main_vs_stable": {"main_commits_ahead_of_v1_3_1": 630, "note": "queried with gh api compare v1.3.1...main on 2026-10-22; external-dependency enforcement sits in [Unreleased]"},
}
print(save("release-churn", out))
print(json.dumps({k: out["beads"][k] for k in ("latest_stable", "stable_tags_since_v1_0_0", "tags_since_v1_0_0_incl_rc", "tags_per_month")}, indent=1))
print(out["dolt"]["minor_versions_published_after_pin"], out["dolt"]["latest_stable"])
