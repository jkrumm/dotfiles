#!/usr/bin/env python3
"""Hermetic suite for caddy-registry.py: the port rows, the path column, and every refusal.

Real `caddy adapt` is used so the route shapes are Caddy's own; the cases that Caddyfile
syntax cannot express (several OR'd matcher sets) are fed as adapted JSON.
Run: python3 -I scripts/lib/caddy-registry.test.py
"""

import importlib.util
import os
import shutil
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("caddy_registry", os.path.join(HERE, "caddy-registry.py"))
reg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reg)

CADDY = shutil.which("caddy")
TRACKED = os.path.join(HERE, "..", "..", "config", "Caddyfile")


def run(caddyfile: str):
    return reg.extract(reg.adapt(reg.prepare_source(caddyfile), CADDY))


def block(body: str) -> str:
    return "x.test {\n" + body + "\n}\n"


@unittest.skipUnless(CADDY, "caddy not installed")
class Registry(unittest.TestCase):
    def test_plain_port_row_is_unchanged(self):
        rows, skipped = run("foo.test {\n\treverse_proxy localhost:7001\n}\n")
        self.assertEqual(rows, [("foo", 7001, 0, "-")])
        self.assertEqual(skipped, [])

    def test_host_rewrite_row_is_unchanged(self):
        rows, _ = run("foo.test {\n\treverse_proxy localhost:7001 {\n\t\theader_up Host localhost:7001\n\t}\n}\n")
        self.assertEqual(rows, [("foo", 7001, 1, "-")])

    def test_redir_sibling_of_an_unrestricted_proxy_is_not_a_restriction(self):
        rows, skipped = run("foo.test {\n\tredir / /map/ 302\n\treverse_proxy localhost:7001\n}\n")
        self.assertEqual(rows, [("foo", 7001, 0, "-")])
        self.assertEqual(skipped, [])

    def test_audio_door_carries_its_paths(self):
        rows, skipped = run(
            block("\t@door path /v1/audio/* /audio/*\n\thandle @door {\n\t\treverse_proxy localhost:7792\n\t}\n\thandle {\n\t\trespond 404\n\t}")
        )
        self.assertEqual(rows, [("x", 7792, 0, "/v1/audio/*,/audio/*")])
        self.assertEqual(skipped, [])

    def test_tracked_caddyfile_audio_row(self):
        with open(TRACKED, encoding="utf-8") as fh:
            rows, _ = run(fh.read())
        self.assertIn(("audio", 7792, 0, "/v1/audio/*,/audio/*"), rows)

    def test_second_path_restricted_door_carries_its_own_paths(self):
        rows, skipped = run(
            "agw-image.test {\n\t@door path /door/image/*\n\thandle @door {\n\t\treverse_proxy localhost:7791\n\t}\n\thandle {\n\t\trespond 404\n\t}\n}\n"
            + block("\t@door path /v1/audio/* /audio/*\n\thandle @door {\n\t\treverse_proxy localhost:7792\n\t}\n\thandle {\n\t\trespond 404\n\t}")
        )
        self.assertEqual(rows, [("agw-image", 7791, 0, "/door/image/*"), ("x", 7792, 0, "/v1/audio/*,/audio/*")])
        self.assertEqual(skipped, [])

    def test_tracked_caddyfile_agw_image_row(self):
        with open(TRACKED, encoding="utf-8") as fh:
            rows, _ = run(fh.read())
        self.assertIn(("agw-image", 7791, 0, "/door/image/*"), rows)

    def assertRefused(self, caddyfile: str, reason: str):
        rows, skipped = run(caddyfile)
        self.assertEqual(rows, [], skipped)
        self.assertEqual(len(skipped), 1, skipped)
        self.assertIn(reason, skipped[0])

    def test_refuses_a_sibling_fallback_that_is_not_404(self):
        self.assertRefused(
            block("\t@door path /audio/*\n\thandle @door {\n\t\treverse_proxy localhost:7792\n\t}\n\thandle {\n\t\trespond \"hello\" 200\n\t}"),
            "not a plain 404",
        )

    def test_refuses_a_second_matcher_route(self):
        self.assertRefused(
            block("\t@a path /a/*\n\t@b path /b/*\n\thandle @a {\n\t\treverse_proxy localhost:7792\n\t}\n\thandle @b {\n\t\trespond 200\n\t}\n\thandle {\n\t\trespond 404\n\t}"),
            "not a plain 404",
        )

    def test_refuses_handle_path(self):
        self.assertRefused(
            block("\thandle_path /audio/* {\n\t\treverse_proxy localhost:7792\n\t}\n\thandle {\n\t\trespond 404\n\t}"),
            "rewrite",
        )

    def test_refuses_a_non_path_matcher(self):
        self.assertRefused(
            block("\t@m {\n\t\tpath /audio/*\n\t\tmethod POST\n\t}\n\thandle @m {\n\t\treverse_proxy localhost:7792\n\t}\n\thandle {\n\t\trespond 404\n\t}"),
            "matcher other than path",
        )


class AdaptedJson(unittest.TestCase):
    def test_refuses_several_matcher_sets(self):
        proxy = {"handler": "reverse_proxy", "upstreams": [{"dial": "localhost:7792"}]}
        route = {
            "match": [{"host": ["x.test"]}],
            "handle": [
                {
                    "handler": "subroute",
                    "routes": [
                        {"match": [{"path": ["/a/*"]}, {"path": ["/b/*"]}], "handle": [proxy]},
                        {"handle": [{"handler": "static_response", "status_code": 404}]},
                    ],
                }
            ],
        }
        config = {"apps": {"http": {"servers": {"s": {"routes": [route]}}}}}
        rows, skipped = reg.extract(config)
        self.assertEqual(rows, [])
        self.assertIn("several matcher sets", skipped[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
