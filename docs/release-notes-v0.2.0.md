Farshore's first public **read-only macOS beta**.

- Browse existing SSH aliases, SSH Home, Root and arbitrary permitted paths.
- Resume saved tabs and display choices; keep favorite servers and folders.
- Open images, PDF/Office documents and text inside Farshore. Stream video/audio with an installed official VLC 3 application, or choose Open With.
- Use `/` to jump to a path or one of five recent destinations.
- Generate folder-wide video thumbnails, set the cache budget, clear generated images and copy redacted diagnostics in Settings.
- Recover from helper exits and interrupted folder reads with bounded retries and cancellation.
- Choose six themes and a native app icon.

The Apple Silicon app bundles Python, rclone and the native helper. A checkout, Flutter and full Xcode are unnecessary to run it. Existing working SSH authentication is required. VLC is optional and is not redistributed.

**This beta is ad hoc signed and not notarized. macOS may block the download.** Local validation uses macOS 26.4; Intel and older systems have not completed acceptance. The source can be built with Command Line Tools. Remote writes and explicit transfers are not enabled. External-file NFS access remains experimental; broader multi-gigabyte media and sleep/wake acceptance are still open.

Download the ZIP, verify it with `SHA256SUMS`, unzip and move `Farshore.app` to Applications. Quit the previous version before replacing it. Preferences survive upgrades. See [installation/migration](https://github.com/Awaisryk/farshore/blob/main/docs/releases.md) and [remaining release gates](https://github.com/Awaisryk/farshore/blob/main/docs/production-readiness.md).

Validation: 150 Flutter tests, 73 backend/packaging tests and clean analysis, plus native bundle/runtime, preview, playback and accessibility smoke checks described in the repository. Source uses MIT; dependency notices are included in the app and available through Settings.

The companion `Farshore-0.2.0-rclone-corresponding-source.zip` supplies the exact rclone/dependency sources and rebuild/replacement instructions, including LGPL/MPL components. It is an optional source download; it is not needed to run the app. The app retains the original dependency notices and source-availability details.
