# Farshore

A read-only macOS file browser for existing SSH connections, with native previews, streamed playback and configurable desktop applications. Product requirements: [PRD.md](PRD.md).

Brand assets: [logo, native app icon and favicon set](assets/branding/README.md). Distribution gates: [production readiness](docs/production-readiness.md).

## Install the beta

Download the Apple Silicon build from [GitHub Releases](https://github.com/Awaisryk/farshore/releases). Unzip it and move `Farshore.app` to Applications. The beta bundles Python, rclone and the native helper; a checkout, Flutter and Xcode are unnecessary to run it. Your existing OpenSSH configuration and working batch authentication are required. Internal audio/video playback additionally requires the official VLC 3 application; other file previews and external opening work without it.

This first beta is ad hoc signed and **not notarized**. macOS can block a downloaded copy; building from source is available below. It has been checked on Apple Silicon macOS 26.4. Older macOS releases and Intel builds have not been validated.

## Build — no full Xcode

The development app uses Flutter and an AppKit host compiled by the installed **Command Line Tools**. No Xcode application, xcodebuild, CocoaPods, or web wrapper is required.

```sh
scripts/bootstrap.sh
scripts/build-app.sh --run
```

Open `build/Farshore.app` in Finder after building. The build produces a standalone app with pinned, hash-verified runtimes. Use the build script rather than `flutter run -d macos`, which follows the ordinary full-Xcode build pipeline. See [release and migration instructions](docs/releases.md).

Builds use optimized release AOT by default, including an optimized Swift host. Use `scripts/build-app.sh --debug` only when debugging; debug/JIT builds are unsuitable for judging UI smoothness. Reopen the app after rebuilding to load the new bundle.

## What works

Home brings together your actual saved servers, five recent folders, open tabs, thumbnail cache usage, file-access sessions and recent opening activity. It remains available in the sidebar and tab bar. Saved tabs restore as disconnected folders until you explicitly resume them. The first six servers appear with favorites first; expand the section to see every configured alias. Returning to Home preserves your browsing state without connecting to servers; choose an open folder to resume it. Status values show their last successful check and retain an explicit warning if refresh fails.

Real SSH alias discovery, strict verification, read-only SFTP browsing, tabs, breadcrumbs/direct paths, back/forward, grid/list/gallery, filters/sort, hidden files, multiselection, keyboard navigation, light/dark appearance, inspector, progressive image thumbnails and native Open With are implemented. Remembered application choices affect Farshore only.

Double-click or press Return to open supported files **inside Farshore**. Images (including PNG), PDFs and common Office/OpenDocument/iWork files use an embedded macOS Quick Look preview. Text, Markdown, JSON, logs, configuration and source files open as selectable plain text; HTML is displayed as source. Audio uses the same internal playback controls as video. Space opens the corresponding quick preview. Unknown types retain external opening; **Open With** is also available from every viewer, including failed or unsupported previews. A supported preview failure never silently launches another app.

Document previews use private temporary snapshots read directly over SSH, without an NFS mount: up to 64 MiB per image, 32 MiB per document, or the first 512 KiB of text. Truncated text is labeled. Copies are removed when the preview closes; preparing, canceled and failed requests also have bounded cleanup. macOS's installed Quick Look providers determine which document variants render. Audio/video continue to stream instead of using the document-copy path.

Click a server's star to keep it at the top of Connections and Home; favorites persist across launches. The browser toolbar's **SSH Home** opens the SSH home directory, **Root** opens `/`, and **Go to folder** (`⌘L`) accepts paths such as `/data` or `/data2`, subject to the remote account's permissions. Farshore's own **Home** page is a separate destination.

Press **/** outside a text field to open the app's path launcher. Enter a path or choose one of the five most recent destinations, labeled by server. Successful launcher visits are saved across restarts; reopening one moves it to the top. Slashes inside text fields remain ordinary input.

Use the folder star to save a favorite path. **Settings** lists favorite folders, controls workspace restoration and the 128 MiB–2 GiB thumbnail budget, clears generated thumbnails, and copies redacted diagnostics. Open tabs, active location, view, density, sort, hidden-file and inspector choices persist. File contents, SSH credentials and selections are not saved in the workspace. A failed helper restarts on a subsequent request; interrupted folder reads retry twice with a Cancel control, while trust/authentication failures stop immediately.

Choose the **palette button at the bottom of the sidebar** for six workspace themes: Shore, Deep Shore, Frost, Sand, Midnight and Orchid. The preview cards apply a theme immediately across Home, the browser and player controls. Your choice persists across launches; switching themes keeps the current folder and selection.

Videos open inside Farshore using **LibVLC**, with play/pause, seeking, volume and an explicit Open With fallback. Farshore verifies the official VideoLAN signature before loading an installed VLC 3 application; it does not redistribute VLC. In-app media uses a token-protected, single-file loopback range endpoint backed by SSH, avoiding NFS for internal playback.

Visible videos also receive cached thumbnails when macOS's AVFoundation decoder supports their format. Thumbnail workers use bounded range reads, run outside the UI process, and yield to playback. Unsupported, slow or over-budget videos keep their file icon. No server-side software or local ffmpeg runtime dependency is required.

For a large folder, use **Generate video thumbnails** to prepare every video already listed in that folder without scrolling. The progress row shows ready/total, cancellation and **Retry missing**. Visible previews take priority; temporary failures retry with bounded backoff, and playback pauses background generation. Cached previews remain available while playing a video. This action does not scan subfolders.

The experimental mount engine exports only the selected directory over local loopback NFS; remote traffic remains SSH. Opening checks an actual mounted-file read and never silently creates a full local copy. Mounts can outlive tabs and quitting. Close external files before unmounting their volumes in Finder.

**This is a read-only beta.** Mounted reads and seeks passed after earlier macOS system-policy denials, but cold NFS reads have also stalled. Multi-gigabyte playback, two selected-player scenarios, exact transfer accounting and cache pressure still need validation. No remote writes, transfers or recursive search are exposed. See [technical validation](docs/technical-validation.md) and [implementation status](docs/implementation-status.md).

## Check

```sh
python3 -m unittest discover -s tests -v
FLUTTER_SUPPRESS_ANALYTICS=true XDG_CONFIG_HOME="$PWD/.tools/flutter-config" \
  .tools/flutter/bin/flutter --no-version-check analyze
FLUTTER_SUPPRESS_ANALYTICS=true XDG_CONFIG_HOME="$PWD/.tools/flutter-config" \
  .tools/flutter/bin/flutter --no-version-check test
scripts/build-native.sh --check
python3 scripts/validate-read-path.py YOUR_ALIAS 'existing/video.mp4'
```

Tools, builds, private logs, preferences, thumbnail caches and measurements are ignored by `.gitignore`. Source is published under the [MIT license](LICENSE). Bundled dependency notices are available in Settings → Open-source licenses and in the application resources. See [decisions](docs/decisions.md) and [dependency inventory](docs/dependencies.md).
