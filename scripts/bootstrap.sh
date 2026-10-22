#!/bin/bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'This bootstrap currently supports Apple Silicon macOS. See docs/decisions.md.' >&2
  exit 1
fi
mkdir -p .tools
if [[ ! -x .tools/rclone-v1.75.2-osx-arm64/rclone ]]; then
  curl --fail --location --retry 2 https://downloads.rclone.org/v1.75.2/rclone-v1.75.2-osx-arm64.zip -o .tools/rclone.zip
  /usr/bin/python3 - <<'PY'
import hashlib, pathlib, zipfile
p = pathlib.Path('.tools/rclone.zip')
expected = '610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd'
if hashlib.sha256(p.read_bytes()).hexdigest() != expected:
    raise SystemExit('rclone SHA-256 mismatch; refusing to extract')
with zipfile.ZipFile(p) as archive:
    archive.extractall('.tools')
PY
  chmod +x .tools/rclone-v1.75.2-osx-arm64/rclone
fi
if [[ ! -x .tools/flutter/bin/flutter ]]; then
  git clone --depth 1 --branch 3.47.7 https://github.com/flutter/flutter.git .tools/flutter
fi
expected_flutter=abaf9c523780a608bd46686fd5e53740a07077f8
actual_flutter=$(git -C .tools/flutter rev-parse HEAD)
if [[ "$actual_flutter" != "$expected_flutter" ]]; then
  echo 'Unexpected Flutter revision. Refusing to update or reset an existing checkout.' >&2
  exit 1
fi
export FLUTTER_SUPPRESS_ANALYTICS=true
export XDG_CONFIG_HOME="$project_root/.tools/flutter-config"
.tools/flutter/bin/flutter --no-version-check precache --macos
scripts/build-native.sh --check
echo 'Local tools ready. Run scripts/build-app.sh --run. Full Xcode is not needed.'
