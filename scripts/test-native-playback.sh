#!/bin/bash
set -euo pipefail

# Optional live integration test, using CLT only. The manifest is the private
# JSON response from prepare_media; its stream endpoint must remain alive.
# Use a seekable video >=4 seconds. No URL or lease token is printed.
# Usage: scripts/test-native-playback.sh /absolute/private-manifest.json [--legacy-actions]
# --legacy-actions exercises the original seek(0)+play EOF button sequence.
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != --legacy-actions ) ]]; then
  echo 'Usage: scripts/test-native-playback.sh PRIVATE_JSON [--legacy-actions]' >&2
  exit 2
fi
task_build="$task_root/.build"
task_frameworks="$task_root/build/Farshore.app/Contents/Frameworks"
if [[ ! -d "$task_frameworks/FlutterMacOS.framework" ]]; then
  echo 'Build Farshore with scripts/build-app.sh before running native playback tests.' >&2
  exit 1
fi
mkdir -p "$task_build/native-test-module-cache"
cat "$task_root/native/FarshoreVideo.swift" "$task_root/tests/native/playback_smoke.swift" > "$task_build/FarshorePlaybackSmoke.swift"
xcrun swiftc -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos12.0" \
  -module-cache-path "$task_build/native-test-module-cache" \
  -F "$task_frameworks" -framework AppKit -framework FlutterMacOS \
  -Xlinker -rpath -Xlinker "$task_frameworks" \
  "$task_build/FarshorePlaybackSmoke.swift" -o "$task_build/farshore-playback-smoke"

# A hard deadline bounds a stuck decoder, including a stop that never returns.
# Only this test's child is killed; installed/running applications are untouched.
/usr/bin/python3 - "$task_build/farshore-playback-smoke" "$@" <<'PY'
import json
import subprocess
import sys

try:
    result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=85)
    report = json.loads(result.stdout)
except subprocess.TimeoutExpired:
    print(json.dumps({"passed": False, "message": "Native playback test exceeded its hard deadline.", "stopAcknowledged": False}))
    sys.exit(1)
except (ValueError, OSError):
    print(json.dumps({"passed": False, "message": "Native playback test did not return a valid report."}))
    sys.exit(1)
print(json.dumps(report, sort_keys=True))
sys.exit(0 if result.returncode == 0 and report.get("passed") else 1)
PY
