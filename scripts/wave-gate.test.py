#!/usr/bin/env python3
"""Tests for wave-gate.py's plan parser — the mechanical half of /wave's green gate.

Run: python3 scripts/wave-gate.test.py

A false pass here lets a broken close-out spawn its successor unattended (the
exact failure mode Round 2 of the estate audit found nothing caught). A false
fail wedges a legitimate wave chain. Both directions matter.
"""

import importlib.util
import os
import sys
import unittest

_SPEC = importlib.util.spec_from_file_location(
    "wave_gate", os.path.join(os.path.dirname(__file__), "wave-gate.py")
)
wave_gate = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(wave_gate)


SAMPLE_PLAN = """# Estate Round 2

## External blocker — read before starting
Not a wave section, must be ignored.

## Wave 1 — first          <!-- status: done -->
- [x] did a thing
- [x] did another
**Left behind:** branch feat/x, nothing outstanding

## Wave 2 — second         <!-- status: active -->
- [ ] do the next thing
- [x] already done
**Left behind:**

## Wave 3 — third          <!-- status: pending -->
- [ ] not started

## Wave 4 — fourth         <!-- status: blocked, needs a design call -->
- [ ] parked
"""


class ParseWaves(unittest.TestCase):
    def setUp(self):
        self.waves = wave_gate.parse_waves(SAMPLE_PLAN)

    def test_finds_every_wave_including_the_multi_word_status(self):
        names = [w["name"] for w in self.waves]
        self.assertEqual(names, ["Wave 1", "Wave 2", "Wave 3", "Wave 4"])

    def test_status_with_trailing_free_text_parses_to_the_first_word(self):
        wave4 = next(w for w in self.waves if w["name"] == "Wave 4")
        self.assertEqual(wave4["status"], "blocked")

    def test_non_wave_sections_are_ignored(self):
        self.assertNotIn("External blocker — read before starting", [w["name"] for w in self.waves])

    def test_all_checked_true_only_when_every_step_is_ticked(self):
        wave1 = next(w for w in self.waves if w["name"] == "Wave 1")
        wave2 = next(w for w in self.waves if w["name"] == "Wave 2")
        self.assertTrue(wave1["all_checked"])
        self.assertFalse(wave2["all_checked"])

    def test_all_checked_false_when_a_wave_has_no_steps_at_all(self):
        # NOT vacuously true — a "done" wave with zero checklist items has
        # nothing to verify completeness against, which is the failure this
        # check exists to catch, not a pass. Real case: docs/waves/PLAN.md's
        # own Wave 4 is written as prose with no checkboxes.
        waves = wave_gate.parse_waves("## Wave 1 — empty <!-- status: done -->\n**Left behind:** nothing\n")
        self.assertFalse(waves[0]["all_checked"])
        self.assertEqual(waves[0]["unchecked"], [])

    def test_wrapped_bullet_text_is_joined_for_the_outward_facing_scan(self):
        plan = (
            "## Wave 1 — x <!-- status: active -->\n"
            "- [ ] a step that wraps onto a continuation line naming the word\n"
            "      merge only on the second line\n"
            "**Left behind:**\n"
        )
        waves = wave_gate.parse_waves(plan)
        self.assertEqual(
            waves[0]["unchecked"],
            ["a step that wraps onto a continuation line naming the word merge only on the second line"],
        )

    def test_outward_scan_looks_only_at_the_next_unchecked_step(self):
        # A later step naming deploy/merge is the wave agent's own call when it
        # reaches it (the skill's judgment half); the gate must not refuse the
        # spawn for it. The next step, if outward-facing, still refuses.
        self.assertIsNone(wave_gate.outward_next_step(["write the clients", "deploy the canary"]))
        self.assertEqual(wave_gate.outward_next_step(["deploy the canary", "write docs"]), "deploy the canary")
        self.assertIsNone(wave_gate.outward_next_step([]))
        # merge_gate_check is not the verb merge — word boundary holds.
        self.assertIsNone(wave_gate.outward_next_step(["port merge_gate_check to python"]))

    def test_unchecked_captures_only_unticked_step_text(self):
        wave2 = next(w for w in self.waves if w["name"] == "Wave 2")
        self.assertEqual(wave2["unchecked"], ["do the next thing"])

    def test_left_behind_empty_string_when_blank(self):
        wave2 = next(w for w in self.waves if w["name"] == "Wave 2")
        self.assertEqual(wave2["left_behind"], "")

    def test_left_behind_captures_the_trailing_text(self):
        wave1 = next(w for w in self.waves if w["name"] == "Wave 1")
        self.assertEqual(wave1["left_behind"], "branch feat/x, nothing outstanding")


class ResolvePlanPath(unittest.TestCase):
    def test_relative_ref_joins_the_repo_path(self):
        got = wave_gate.resolve_plan_path("/repo", "docs/waves/PLAN.md")
        self.assertEqual(got, "/repo/docs/waves/PLAN.md")

    def test_absolute_ref_is_used_as_is(self):
        got = wave_gate.resolve_plan_path("/repo", "/elsewhere/docs/waves/PLAN.md")
        self.assertEqual(got, "/elsewhere/docs/waves/PLAN.md")

    def test_tilde_ref_expands_against_home_not_the_repo_path(self):
        got = wave_gate.resolve_plan_path("/repo", "~/SourceRoot/dotfiles/docs/waves/PLAN.md")
        self.assertEqual(got, os.path.expanduser("~/SourceRoot/dotfiles/docs/waves/PLAN.md"))
        self.assertNotIn("/repo", got)


if __name__ == "__main__":
    unittest.main()
