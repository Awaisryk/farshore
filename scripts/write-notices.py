#!/usr/bin/env python3
"""Build the license-page source from preserved upstream license artifacts."""
from pathlib import Path
import json
import sys
import gzip

app = Path(sys.argv[1])
resources = app / "Contents/Resources"
licenses = resources / "Runtime/licenses"
sections = ["Farshore bundled dependency notices\n\n"
            "The full upstream Python build license directory is preserved for provenance; "
            "it also covers optional upstream components not used by Farshore. "
            "VLC is not bundled; embedded playback uses an independently installed, "
            "authenticated VideoLAN application.\n"]
inventory = licenses / "rclone-third-party/inventory.json"
if inventory.is_file():
    provision = json.loads(inventory.read_text()).get("sourceProvision", {})
    sections.append("Bundled rclone uses github.com/cloudsoda/sddl, covered by the GNU Lesser General Public License version 3, "
                    "and modules covered by the Mozilla Public License 2.0. Their original notices and terms appear below. "
                    "Exact corresponding source and instructions to rebuild/relink rclone with modified libraries and replace/re-sign "
                    "the application are provided with this release: " + provision.get("url", "https://github.com/Awaisryk/farshore/releases") + "\n")
for path in sorted(licenses.rglob("*")):
    named_notice = path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT", "AUTHORS", "PATENTS", "UNLICENSE"))
    if path.is_file() and (path.suffix.lower() in {".txt", ".md"} or named_notice):
        payload = path.read_bytes()
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            text = payload.decode("latin-1")
        sections.append("\n" + "=" * 72 + "\n" + str(path.relative_to(licenses)) + "\n" + "=" * 72 + "\n" + text)
notice = app / "Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z"
if not notice.is_file():
    raise SystemExit("Flutter-generated package notices are missing.")
sections.append("\n" + "=" * 72 + "\nFlutter-generated Dart package notices\n" + "=" * 72 + "\n" + gzip.decompress(notice.read_bytes()).decode("utf-8"))
destination = resources / "THIRD_PARTY_NOTICES.txt"
destination.write_text("\n".join(sections))
print("Consolidated dependency notices written.")
