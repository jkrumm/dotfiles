"""Hermetic tests for the size / item-count decisions in backup-1password.py."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).with_name("backup-1password.py")
spec = importlib.util.spec_from_file_location("backup_1password", SRC)
bp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bp)


class ItemCountDrop(unittest.TestCase):
    def test_first_run_passes(self):
        self.assertFalse(bp.item_count_dropped(None, 5))
        self.assertFalse(bp.item_count_dropped(0, 5))

    def test_small_drop_and_growth_pass(self):
        self.assertFalse(bp.item_count_dropped(100, 80))
        self.assertFalse(bp.item_count_dropped(100, 130))

    def test_over_twenty_percent_refused(self):
        self.assertTrue(bp.item_count_dropped(100, 79))
        self.assertTrue(bp.item_count_dropped(370, 0))


class UploadSize(unittest.TestCase):
    def test_equal_ok(self):
        self.assertTrue(bp.upload_size_ok(1234, 1234))

    def test_mismatch_or_missing_fails(self):
        self.assertFalse(bp.upload_size_ok(1234, 1000))
        self.assertFalse(bp.upload_size_ok(1234, None))


class CountState(unittest.TestCase):
    def test_roundtrip_and_missing(self):
        with tempfile.TemporaryDirectory() as d:
            bp.STATE_DIR = Path(d) / "s"
            bp.COUNT_FILE = bp.STATE_DIR / "last_item_count"
            self.assertIsNone(bp.read_last_count())
            bp.write_last_count(42)
            self.assertEqual(bp.read_last_count(), 42)
            bp.COUNT_FILE.write_text("junk")
            self.assertIsNone(bp.read_last_count())


if __name__ == "__main__":
    unittest.main()
