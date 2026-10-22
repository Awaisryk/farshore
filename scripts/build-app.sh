#!/bin/bash
set -euo pipefail

# Local native Flutter bundle. Release AOT is the default; --debug opts into JIT.
# No Xcode project, CocoaPods, or xcodebuild is used: assemble builds Dart assets
# and the macOS Command Line Tools build the AppKit host.
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_bin="${FARSHORE_FLUTTER:-$project_root/.tools/flutter/bin/flutter}"
published_app="$project_root/build/Farshore.app"
brand_icon="$project_root/assets/branding/Farshore.icns"
architecture="$(uname -m)"
build_mode=release
stage_only=false
run_after_build=false
export FLUTTER_SUPPRESS_ANALYTICS=true
export XDG_CONFIG_HOME="${FARSHORE_FLUTTER_CONFIG:-$project_root/.tools/flutter-config}"

for argument in "$@"; do
    case "$argument" in
        --debug) build_mode=debug ;;
        --release) build_mode=release ;;
        --run) run_after_build=true ;;
        --stage-only) stage_only=true ;;
        *) echo "Usage: scripts/build-app.sh [--debug | --release] [--run | --stage-only]" >&2; exit 2 ;;
    esac
done
if $stage_only && $run_after_build; then
    echo "Choose --run or --stage-only, not both." >&2
    exit 2
fi
flutter_output="$project_root/build/flutter/$build_mode"

if [[ ! -x "$flutter_bin" ]]; then
    echo "Flutter was not found at $flutter_bin. Set FARSHORE_FLUTTER to its executable." >&2
    exit 1
fi
if [[ ! -f "$project_root/pubspec.yaml" ]]; then
    echo "The Flutter project is missing pubspec.yaml." >&2
    exit 1
fi
if [[ ! -s "$brand_icon" ]]; then
    echo "The app icon is missing. Run xcrun swift scripts/generate-brand-assets.swift from the checkout." >&2
    exit 1
fi
package_version="$(awk '$1 == "version:" {print $2; exit}' "$project_root/pubspec.yaml")"
if [[ "$package_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]]; then
    app_version="${BASH_REMATCH[1]}"
    app_build="${BASH_REMATCH[2]}"
else
    echo "pubspec.yaml must declare version: major.minor.patch+build." >&2
    exit 1
fi
flutter_sdk="$(cd -- "$(dirname -- "$flutter_bin")/.." && pwd)"
version_file="$flutter_sdk/bin/cache/flutter.version.json"
flutter_version="$(/usr/bin/plutil -extract frameworkVersion raw -o - "$version_file" 2>/dev/null || true)"
if [[ "$flutter_version" != 3.47.7 ]]; then
    echo "This runner is pinned to Flutter 3.47.7; run scripts/bootstrap.sh or set FARSHORE_FLUTTER to that SDK." >&2
    exit 1
fi
case "$architecture" in
    arm64) ;;
    *) echo "Portable bundles currently support Apple Silicon arm64 only; refusing to bundle incompatible dependencies for $architecture." >&2; exit 1 ;;
esac

cd "$project_root"
mkdir -p "$project_root/build/staging" "$project_root/build/previous"
stage_root="$(mktemp -d "$project_root/build/staging/farshore.XXXXXX")"
app_bundle="$stage_root/Farshore.app"
frameworks="$app_bundle/Contents/Frameworks"
mkdir -p "$frameworks" "$flutter_output" "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$project_root/build/swift-module-cache"

# Calling assemble directly avoids the full-Xcode validation in `build macos`.
# Keep the ordinary framework layout so only public Flutter APIs are needed.
"$flutter_bin" --no-version-check pub get
track_widget_creation=false
tree_shake_icons=true
swift_options=(-O -whole-module-optimization)
if [[ "$build_mode" == debug ]]; then
    track_widget_creation=true
    tree_shake_icons=false
    swift_options=(-Onone)
fi
"$flutter_bin" --no-version-check assemble \
    --output="$flutter_output" \
    -dTargetPlatform=darwin \
    -dBuildMode="$build_mode" \
    -dTargetFile=lib/main.dart \
    -dDarwinArchs="$architecture" \
    -dTreeShakeIcons="$tree_shake_icons" \
    -dTrackWidgetCreation="$track_widget_creation" \
    "${build_mode}_macos_bundle_flutter_assets"

# Assemble also emits bookkeeping files, which must stay outside Frameworks:
# codesign interprets files there as nested code rather than ordinary resources.
/usr/bin/rsync -a --delete "$flutter_output/FlutterMacOS.framework/" "$frameworks/FlutterMacOS.framework/"
/usr/bin/rsync -a --delete "$flutter_output/App.framework/" "$frameworks/App.framework/"
/bin/rm -f "$frameworks/.last_build_id"

cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Farshore</string>
  <key>CFBundleDisplayName</key><string>Farshore</string>
  <key>CFBundleIdentifier</key><string>dev.farshore.desktop</string>
  <key>CFBundleExecutable</key><string>Farshore</string>
  <key>CFBundleIconFile</key><string>Farshore.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Farshore connects to the SSH hosts you select on your local network.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Farshore reads files through the local filesystem bridge for previews and your selected applications.</string>
</dict></plist>
PLIST
/usr/bin/plutil -insert FarshoreDevelopmentRoot -string "$project_root" "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -insert FarshoreBuildMode -string "$build_mode" "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$app_version" "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$app_build" "$app_bundle/Contents/Info.plist"
/bin/cp "$brand_icon" "$app_bundle/Contents/Resources/Farshore.icns"
/usr/bin/plutil -remove FarshoreDevelopmentRoot "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -insert FarshorePortableRuntime -bool true "$app_bundle/Contents/Info.plist"
"$project_root/scripts/build-native.sh" --check
/usr/bin/python3 "$project_root/scripts/prepare-runtime.py" "$app_bundle/Contents/Resources/Runtime"
if [[ -f "$project_root/LICENSE" ]]; then
    /bin/cp "$project_root/LICENSE" "$app_bundle/Contents/Resources/Runtime/licenses/Farshore-MIT.txt"
fi
/usr/bin/python3 "$project_root/scripts/write-notices.py" "$app_bundle"

# The runner declares its @main entrypoint; compile media integration in the
# same Swift module without introducing another top-level entrypoint.
runner_sources=("$project_root/native/FarshoreApp.swift")
runner_sources+=("$project_root/native/FarshoreRuntime.swift")
if [[ -f "$project_root/native/FarshoreVideo.swift" ]]; then
    runner_sources+=("$project_root/native/FarshoreVideo.swift")
fi
runner_sources+=("$project_root/native/FarshorePreview.swift")

xcrun swiftc \
    -parse-as-library \
    "${swift_options[@]}" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$architecture-apple-macos12.0" \
    -module-cache-path "$project_root/build/swift-module-cache" \
    -F "$frameworks" \
    -framework AppKit -framework FlutterMacOS -framework QuickLookUI -framework Security \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    "${runner_sources[@]}" \
    -o "$app_bundle/Contents/MacOS/Farshore"

if [[ "$build_mode" == debug ]]; then
    cat > "$project_root/build/Debug.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict></plist>
PLIST
else
    # A release engine loads native AOT code. Fail if a stale JIT kernel slipped
    # into the app, rather than silently shipping a mixed-mode bundle.
    for jit_asset in kernel_blob.bin vm_snapshot_data isolate_snapshot_data; do
        if [[ -e "$frameworks/App.framework/Resources/flutter_assets/$jit_asset" ]]; then
            echo "Release build unexpectedly contains JIT asset $jit_asset." >&2
            exit 1
        fi
    done
    # Flutter 3.47's public snapshot loader resolves these merged AOT symbols.
    aot_symbols="$(xcrun nm -gj "$frameworks/App.framework/App")"
    if [[ "$aot_symbols" != *"_kDartSnapshotData"* || "$aot_symbols" != *"_kDartSnapshotText"* ]]; then
        echo "Release App.framework is missing its native AOT snapshot exports." >&2
        exit 1
    fi
    xcrun strip -x "$app_bundle/Contents/MacOS/Farshore"
fi

# Sign Python/native/rclone code as well as the frameworks, inside out.
if [[ "$build_mode" == debug ]]; then
    /usr/bin/python3 "$project_root/scripts/sign-app.py" "$app_bundle" --debug
else
    /usr/bin/python3 "$project_root/scripts/sign-app.py" "$app_bundle"
fi
/usr/bin/codesign --verify --deep --strict "$app_bundle"
if $stage_only; then
    echo "Staged verified $build_mode app at $app_bundle"
    exit 0
fi

# Never rewrite code or assets inside an app that may still be running. Retain
# its complete bundle until the user has finished that application session.
previous_bundle=""
if [[ -e "$published_app" ]]; then
    previous_root="$(mktemp -d "$project_root/build/previous/farshore.XXXXXX")"
    previous_bundle="$previous_root/Farshore.app"
    /bin/mv "$published_app" "$previous_bundle"
fi
if ! /bin/mv "$app_bundle" "$published_app"; then
    if [[ -n "$previous_bundle" ]]; then
        /bin/mv "$previous_bundle" "$published_app"
    fi
    echo "The verified app remains in $app_bundle; publication failed." >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$published_app"
echo "Built $build_mode app at $published_app"
if [[ -n "$previous_bundle" ]]; then
    echo "Retained the previous bundle at $previous_bundle for any running session."
fi

if $run_after_build; then
    /usr/bin/open "$published_app"
fi
