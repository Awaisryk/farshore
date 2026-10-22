#!/usr/bin/env python3
"""Verify all release digests and the extracted portable app, without GUI."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "dist").resolve()
manifest = json.loads((output / "release-manifest.json").read_text())


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


verified = []
for line in (output / "SHA256SUMS").read_text().splitlines():
    expected, name = line.split("  ", 1)
    assert Path(name).name == name and digest(output / name) == expected, "Release digest mismatch."
    verified.append(name)
artifact = output / manifest["artifact"]
source_info = manifest["correspondingSource"]
source = output / source_info["asset"]
assert digest(artifact) == manifest["sha256"]
assert digest(source) == source_info["sha256"]
assert source_info["url"].startswith("https://github.com/Awaisryk/farshore/releases/download/")
assert source_info["url"].endswith("/" + source.name)
assert {artifact.name, source.name, "release-manifest.json"}.issubset(verified)
with zipfile.ZipFile(source) as archive:
    assert archive.testzip() is None, "Corresponding-source ZIP is damaged."
    assert any(name.endswith("source-manifest.json") for name in archive.namelist())
with tempfile.TemporaryDirectory(prefix="farshore-release-verify-", dir="/private/tmp") as temporary:
    extracted = Path(temporary)
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(artifact), str(extracted)], check=True)
    app = extracted / "Farshore.app"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    resources = app / "Contents/Resources"
    notices = (resources / "THIRD_PARTY_NOTICES.txt").read_text()
    inventory = json.loads((resources / "Runtime/licenses/rclone-third-party/inventory.json").read_text())
    assert inventory["complete"] is True and inventory["moduleCount"] == 242
    assert inventory["sourceProvision"]["sha256"] == source_info["sha256"]
    assert source_info["url"] in notices and "github.com/cloudsoda/sddl" in notices
    assert "GNU LESSER GENERAL PUBLIC LICENSE" in notices.upper()
    smoke = subprocess.run([sys.executable, str(ROOT / "scripts/test-portable-app.py"), str(app)],
                           check=True, capture_output=True, text=True, timeout=90)
    result = json.loads(smoke.stdout)
    assert result["ok"] and result["visibleWindow"] is False and result["userStateTouched"] is False
print(json.dumps({"ok": True, "releaseDigestsVerified": len(verified), "correspondingSourceZipValid": True,
                  "extractedSignatureValid": True, "completeDependencyNotices": True,
                  "extractedPortableAppVerified": True, "visibleWindow": False, "userStateTouched": False}))
