#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/test-native-video-thumbnail.sh [LOCAL_VIDEO]' >&2
  exit 2
fi
"$task_root/scripts/build-native.sh"
exec python3 "$task_root/tests/native/video_thumbnail_smoke.py" --helper "$task_root/.build/farshore-native" "$@"
