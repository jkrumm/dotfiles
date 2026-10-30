---
name: compute-and-render
description: How to compute with python3/bun and render a chart or diagram to a file in this environment. Use whenever a result should be a number plus a picture.
---

# Compute and render

Installed: `python3` (stdlib only, no matplotlib), `bun`, `uv`. NOT installed: `mmdc`, `dot`, ImageMagick.

1. Compute with a short python3 script saved in the workdir (`json`, `statistics`, `csv` are enough).
2. Render an SVG chart by writing the SVG text yourself from the script (rects, text, axes). It is
   a file, it opens in any browser, and it needs no dependency.
3. A PNG is optional: `uv run --with matplotlib python chart.py` works (network, first run ~10 s).
4. A diagram (flow, sequence) is also fine as hand-written SVG.
5. Check the result: `ls -l` the files and `head -c 300` the SVG before you report them.
