#!/bin/bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
export FLUTTER_SUPPRESS_ANALYTICS=true
export XDG_CONFIG_HOME="$project_root/.tools/flutter-config"
# Actual FarshoreApp widgets, an in-memory bridge and original procedural art.
# This artifact generator is outside test/ and never reads user/SSH state.
exec .tools/flutter/bin/flutter --no-version-check test tool/readme_screenshots_test.dart --reporter expanded
