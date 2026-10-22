import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("migration", Path(__file__).resolve().parents[1] / "scripts/migrate-state.py")
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def test_copy_only_preserves_mounts_existing_preferences_and_cache_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "legacy"
            source.mkdir(mode=0o700)
            (source / "thumbnails").mkdir(mode=0o700)
            (source / "mounts/live").mkdir(parents=True)
            (source / "mounts/live/marker").write_text("untouched")
            (source / "mount-registry.json").write_text('{"version":1,"mounts":[]}')
            (source / "preferences.json").write_text('{"themeId":"orchid"}')
            thumbnail = source / "thumbnails/abc.png"
            thumbnail.write_bytes(b"fixture-png")
            (source / "thumbnails/partial.part.png").write_bytes(b"partial")
            (source / "thumbnails/linked.png").symlink_to(source / "preferences.json")
            state, cache = root / "state", root / "cache"
            first = migration.migrate(source, state, cache)
            self.assertTrue(first["preferencesCopied"])
            self.assertEqual(first["thumbnailFilesCopied"], 1)
            self.assertEqual((state / "preferences.json").read_text(), '{"themeId":"orchid"}')
            self.assertEqual(stat.S_IMODE((cache / "thumbnails/abc.png").stat().st_mode), 0o600)
            self.assertEqual((source / "mounts/live/marker").read_text(), "untouched")
            self.assertTrue((source / "mount-registry.json").exists())
            self.assertFalse((state / "mounts").exists())
            (source / "preferences.json").write_text('{"themeId":"sand"}')
            second = migration.migrate(source, state, cache)
            self.assertFalse(second["preferencesCopied"])
            self.assertEqual(second["thumbnailFilesCopied"], 0)
            self.assertEqual(json.loads((state / "legacy-states.json").read_text())["roots"], [str(source.resolve())])
            self.assertEqual(json.loads((state / "preferences.json").read_text())["themeId"], "orchid")

    def test_rejects_unowned_shape_destinations_and_public_legacy_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "legacy"
            legacy.mkdir(mode=0o755)
            with self.assertRaises(ValueError):
                migration.migrate(legacy, root / "state", root / "cache")
            legacy.chmod(0o700)
            target = root / "target"
            target.mkdir()
            state = root / "state"
            state.symlink_to(target, target_is_directory=True)
            with self.assertRaises(ValueError):
                migration.migrate(legacy, state, root / "cache")


if __name__ == "__main__":
    unittest.main()
