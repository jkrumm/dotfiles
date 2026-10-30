---
name: research-cli
description: How to run the research CLI for one quick, cited research job. Use for any factual question.
---

# research CLI

`research "<question>" --depth quick --json` submits a job, waits, and prints the result as JSON
(report, citations, jobId, status, unverified). Quick jobs take about 10-30 seconds.

- One job per question. Do not poll; the command already waits.
- Surface `status` when it is not `ok`, and the `unverified` list.
- Do not pass `--depth deep`.
