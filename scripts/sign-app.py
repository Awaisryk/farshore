#!/usr/bin/env python3
"""Sign all nested runtime code before its containing frameworks/application."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
         b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve()
    identity = os.environ.get("FARSHORE_SIGN_IDENTITY", "-")
    if identity != "-" and not identity.startswith("Developer ID Application:"):
        raise SystemExit("Distribution signing requires an explicit Developer ID Application identity.")
    hardened = identity != "-"

    def sign(path, entitlements=None):
        command = ["/usr/bin/codesign", "--force", "--sign", identity,
                   "--timestamp" if hardened else "--timestamp=none"]
        if hardened:
            command += ["--options", "runtime"]
        if entitlements:
            command += ["--entitlements", str(entitlements), "--generate-entitlement-der"]
        subprocess.run(command + [str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    count = 0
    for path in sorted(app.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as source:
            is_code = source.read(4) in MAGIC
        if is_code:
            sign(path)
            count += 1
    for path in sorted(app.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True):
        if not path.is_symlink():
            sign(path)
    with tempfile.TemporaryDirectory(prefix="farshore-entitlements-") as directory:
        entitlements = Path(directory) / "entitlements.plist"
        # Installed VideoLAN code is authenticated by our Security.framework
        # requirement before loading; allowing its different team is deliberate.
        values = {"com.apple.security.cs.disable-library-validation": True}
        if args.debug:
            values["com.apple.security.cs.allow-jit"] = True
        entitlements.write_bytes(plistlib.dumps(values))
        sign(app, entitlements)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Signed {} Mach-O files; mode={}.".format(count, "developer-id" if hardened else "ad-hoc-unnotarized-beta"))


if __name__ == "__main__":
    main()
