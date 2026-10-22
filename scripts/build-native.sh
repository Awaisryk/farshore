#!/bin/sh
set -eu

# Command Line Tools are sufficient; the full Xcode application is not used.
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_build="$task_root/.build"
case "${1:-}" in
  ""|--check) ;;
  *) echo 'Usage: scripts/build-native.sh [--check]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo 'Usage: scripts/build-native.sh [--check]' >&2
  exit 2
fi
mkdir -p "$task_build/native-module-cache"
task_stage=$(mktemp -d "$task_build/native-build.XXXXXX")
trap 'rm -rf -- "$task_stage"' 0
task_arch=$(uname -m)
case "$task_arch" in
  arm64|x86_64) ;;
  *) echo 'Unsupported macOS build architecture.' >&2; exit 1 ;;
esac
task_sdk=$(xcrun --sdk macosx --show-sdk-path)
# Swift 5 language mode keeps AppKit callbacks compatible with CLT releases
# predating complete Swift concurrency annotations. All AppKit work is on main.
xcrun --sdk macosx swiftc \
  -swift-version 5 -O \
  -sdk "$task_sdk" \
  -target "$task_arch-apple-macosx12.0" \
  -module-cache-path "$task_build/native-module-cache" \
  -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers \
  "$task_root/native/FarshoreNative.swift" \
  -o "$task_stage/farshore-native"
# Publish a complete new inode so active thumbnail processes keep their loaded
# executable intact while a helper update is compiled and verified.
/usr/bin/codesign --force --sign - "$task_stage/farshore-native"
/usr/bin/codesign --verify --strict "$task_stage/farshore-native"
if [ "${1:-}" = --check ]; then
  "$task_stage/farshore-native" self-check
fi
mv -f "$task_stage/farshore-native" "$task_build/farshore-native"
