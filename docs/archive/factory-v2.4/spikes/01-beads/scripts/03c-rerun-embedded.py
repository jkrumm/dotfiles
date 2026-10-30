#!/usr/bin/env python3
"""Spike 1, step 3 (correction pass): re-run the corrected per-op series (close now passes the claiming
actor; the first embedded run measured 20 refused closes) and the external-dependency matrix on the
already-loaded embedded topology. Usage: python3 -I 03c-rerun-embedded.py  -> results/topology-embedded-rerun.json"""
import importlib.util
import os
import sys

sys.argv = [sys.argv[0], "embedded"]
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("topologies", os.path.join(here, "03-topologies.py"))
topo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(topo)
out = {"topology": "embedded", "loadavg_at_start": topo.loadavg()}
out["ops_df"] = topo.bench_ops(f"{topo.ROOT}/dotfiles")
out["external"] = topo.external_deps()
out["loadavg_at_end"] = topo.loadavg()
print(topo.save("topology-embedded-rerun", out))
