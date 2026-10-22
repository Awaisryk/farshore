import gzip
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class NoticeTests(unittest.TestCase):
    def test_gzip_flutter_notices_and_original_extensionless_licenses_are_included(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Fixture.app"
            resources = app / "Contents/Resources"
            licenses = resources / "Runtime/licenses/module"
            licenses.mkdir(parents=True)
            for name in ["LICENSE", "COPYING", "NOTICE", "license.md"]:
                (licenses / name).write_text("Upstream original " + name)
            (licenses / "inventory.json").write_text('{"secret":"not-a-license"}')
            (licenses / "collect.py").write_text("not-a-license-script")
            assets = app / "Contents/Frameworks/App.framework/Resources/flutter_assets"
            assets.mkdir(parents=True)
            (assets / "NOTICES.Z").write_bytes(gzip.compress(b"Flutter generated package copyright"))
            script = Path(__file__).resolve().parents[1] / "scripts/write-notices.py"
            subprocess.run([sys.executable, str(script), str(app)], check=True, capture_output=True)
            notice = (resources / "THIRD_PARTY_NOTICES.txt").read_text()
            for name in ["LICENSE", "COPYING", "NOTICE", "license.md"]:
                self.assertIn("Upstream original " + name, notice)
            self.assertIn("Flutter generated package copyright", notice)
            self.assertNotIn("not-a-license", notice)


if __name__ == "__main__":
    unittest.main()
