# Spike 3 — correlation backtest on the golden set

- Status: result, input to ADR-003. Date 2026-10-22. The full, reproducible report section is rendered by `evidence/golden/backtest.py` into `evidence/golden/backtest.out.md` ("Report section"); `backtest.py --verify` reproduces both outputs byte for byte. This file is the spike agent's final summary, saved verbatim by the orchestrator (subagent report writes are refused).

**Spike 3 backtest, held-out odd chunks scored once.** Grouping and owner-touch pass; escalation and known-error match fail. Pass count 1, script sha256 `78a7b5b4…`, `--verify` reproduces both outputs byte for byte, redaction check clean, nothing committed.

The harness refused `REPORT.md` as a report-style file, so I did not work around it. The MADR-ready section is rendered into `backtest.out.md` ("Report section") and the narrative follows below. The empty `spikes/03-correlation/` directory is left in place.

| Threshold (labelled / flipped, PASS needs both) | Proposed | Today's warden | Keep-style |
|-|-|-|-|
| B-cubed P ≥ 0.90 | 0.937 / 0.902 PASS | 0.993 PASS | 0.968 PASS |
| B-cubed R ≥ 0.80 | 0.846 / 0.881 PASS | 0.595 FAIL | 0.595 FAIL |
| F1 above warden | 0.889 / 0.891 PASS | 0.744 reference | 0.737 FAIL |
| Escalation recall 1.00 | 0/1 caught, the miss is uncertain; flipped 0/7. FAIL | 0/1; flipped 6/7. FAIL | same as Proposed |
| Escalation precision ≥ 0.80 | 0/4 FAIL | 0/57 FAIL | 0/4 |
| Owner touch ≤ 1 % | 0.62 % PASS (oracle 0.60 %) | 14.09 % FAIL | 0.62 % |
| Known-error match ≥ 0.50 | 0.479 weighted, 1/5 sampled; flipped 0.222. FAIL | 0 FAIL | 0 |
| Known-error false match ≤ 0.05 | 0.007 PASS | 0 | 0 |

- **Dev vs held-out:** grouping P/R/F1 was 0.990/0.887/0.936 on dev. The 95 % intervals on held-out are P [0.893, 0.970] and R [0.797, 0.890], so neither threshold is settled by the sample. The F1 gain over warden is settled: +0.145 [+0.098, +0.194].
- **Frozen parameters:** `w_topo` 45, `k_host` 2, `w_dedup` 720, `w_open` 360, `w_rec` 10080, `w_reopen` 10, `w_chat` 30, `th_sim` 0.2, `w_sim` 240, known-error θ 0.9, gate T 30 / N 1, Keep-style `w_dedup` 1 / `w_corr` 30 / `gate_n` 4.
- **Keep-style:** its best fit scores F1 0.737, the same as leaving every event alone (0.740). Adding the release tag only reaches 0.746. Without topology the proposal scores 0.850; without per-source refinements 0.713.
- **Top error classes (held-out):**
  - Merges: refined-fingerprint dedup (class `fp`) joins agent chat acknowledgements of different releases (`<sha> — ok`), 0.054.
  - Splits, in mass order:
    - long outages, where the window rule is the cause;
    - ticket and brief text that does not overlap;
    - chat lines naming a release sha that are not linked to the deploy;
    - retired or private monitors not in the manifest, which splits one 27-event cascade.
- **Escalation misses:** dev was 5/5 and held-out is 0/4, so the evidence tables overfit five dev positives (revisions are in the dev log). This diagnosis is my post-hoc reading and is not in the artefact.
  - Events 968–970 are one provider billing-cap incident. The policy read "billing" in a `next=human` summary where no decision was asked.
  - Event 1571 is a review-stage `[data_loss]` tag matched by a loose `drop…` pattern.
  - The one genuine decision, 1626, is a backlog issue with no decision question, so a text policy cannot reach it.
- **Escalation power:** the held-out split holds 1 genuine decision (6 of 959 overall), so recall and precision are barely testable. The dual-reading rule is also unsatisfiable when uncertain labels sit on both sides of the boundary. The dev oracle owner-touch share is 1.29 %, above the 1 % rule.
- **Gold labels that matter (listed, not relabelled):**
  - 1372, 1373, 1380, 1381: labeller B says known_fix=n, and their referenced items have no recipe-bearing closure before the event.
  - 1450 and 1451: the referenced PR was closed unmerged.
  - 1074 and 1079 are labelled y but 1071 and 1078 n, all one group with one fingerprint.
- **Recommendation:**
  - Build the proposed correlator and shadow it against warden before it gates anything; do not adopt Keep as the engine.
  - Do not ship the keyword escalation policy. Use the structured investigator decision field implied by ADR-014 and shadow it until about 30 genuine decisions exist.
  - Build the known-error store but attach Changes to incidents. The θ = 0.9 fallback missed cross-source priors (1449 to 1458, 1585 to 1497).
  - Thresholds are not moved. Before writing any rule I listed held-out positive ids and notes; this is disclosed in the artefact.

Files are in `~/SourceRoot/dotfiles/docs/factory/evidence/golden`:
- `backtest.py`
- `backtest.out.json`
- `backtest.out.md`
