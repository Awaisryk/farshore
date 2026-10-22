#!/usr/bin/env python3
"""Relocate the sealed app and run its native/backend CLI without user state/UI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Farshore.app").resolve()
with tempfile.TemporaryDirectory(prefix="farshore-portable-", dir="/private/tmp") as directory:
    temporary = Path(directory)
    app = temporary / "Moved Application/Farshore.app"
    shutil.copytree(source, app, symlinks=True)
    runtime = app / "Contents/Resources/Runtime"
    home = temporary / "home"
    (home / ".ssh").mkdir(parents=True, mode=0o700)
    (home / ".ssh/config").write_text("")
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("FARSHORE_") and key not in {"RCLONE", "PYTHONHOME", "PYTHONPATH"}}
    environment.update(HOME=str(home), PATH="/usr/bin:/bin", FARSHORE_STATE=str(temporary / "state"),
                       FARSHORE_CACHE=str(temporary / "cache"))
    native = subprocess.run([str(app / "Contents/MacOS/Farshore"), "--runtime-self-check"],
                            cwd="/private/tmp", env=environment, capture_output=True, text=True, timeout=15)
    if native.returncode:
        raise SystemExit("Relocated native runtime self-check failed: " + native.stdout)
    check = json.loads(native.stdout)
    assert check["ok"] and check["portable"] and all(check["checks"].values())
    environment.update(FARSHORE_ROOT=str(runtime), FARSHORE_PYTHON=str(runtime / "python/bin/python3"),
                       FARSHORE_BRIDGE_SCRIPT=str(runtime / "backend/farshore_bridge.py"),
                       FARSHORE_NATIVE=str(runtime / "bin/farshore-native"), FARSHORE_RCLONE=str(runtime / "bin/rclone"),
                       FARSHORE_NOTICES=str(app / "Contents/Resources/THIRD_PARTY_NOTICES.txt"))
    python = runtime / "python/bin/python3"
    script = runtime / "backend/farshore_bridge.py"
    for method in ["hosts", "status"]:
        result = subprocess.run([str(python), "-I", "-B", str(script), "call", method],
                                cwd="/private/tmp", env=environment, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, "Relocated backend " + method + " failed."
        response = json.loads(result.stdout)
        assert response["ok"], "Relocated backend returned an error."
        if method == "hosts":
            assert response["result"]["hosts"] == [], "Fixture HOME isolation failed."
    helper = subprocess.run([str(runtime / "bin/farshore-native"), "self-check"],
                            env=environment, capture_output=True, text=True, timeout=10)
    assert helper.returncode == 0 and json.loads(helper.stdout)["ok"]
    engine = subprocess.run([str(runtime / "bin/rclone"), "version"], env=environment,
                            capture_output=True, text=True, timeout=10)
    assert engine.returncode == 0 and "rclone v1.75.2" in engine.stdout
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(json.dumps({"ok": True, "relocatedNativeRuntime": True, "bundledPythonBridge": True,
                      "bundledHelper": True, "bundledRclone": True, "checkoutNeeded": False,
                      "visibleWindow": False, "userStateTouched": False}))
