# Releases and local state

## 0.2.0 beta

The read-only beta adds saved workspaces and favorite folders, Settings with cache controls and redacted diagnostics, helper/network recovery, and a standalone application bundle. It includes native image/document/text previews, streamed audio/video, six themes, a global path launcher and folder-wide thumbnail generation.

Source: [Awaisryk/farshore](https://github.com/Awaisryk/farshore). Downloads: [GitHub Releases](https://github.com/Awaisryk/farshore/releases).

The first package is Apple Silicon, release AOT, ad hoc signed and **not notarized**. Only macOS 26.4 has been validated locally. An official VLC 3 installation enables internal audio/video; VLC is not bundled. Experimental external-file NFS access and the wider media acceptance gates are described in [production readiness](production-readiness.md).

## Install, upgrade and rollback

Unzip `Farshore-0.2.0-macos-arm64-beta.zip` and move `Farshore.app` to Applications. Compare the archive hash against `SHA256SUMS` before installation. Quit the old app, retaining external-file access if needed, then replace the bundle. Keep the previous ZIP for rollback. Preferences and generated thumbnails are separate from the app and survive replacement. This release has no automatic updater.

Local data locations:

| Data | Location |
| --- | --- |
| Preferences, workspace, favorite paths and retained-session metadata | `~/Library/Application Support/Farshore` |
| Generated thumbnail PNGs | `~/Library/Caches/Farshore/thumbnails` |
| Temporary bounded preview snapshots | Application Support `previews` subdirectory; removed on close or stale-owner cleanup |
| Dependency notices | `Farshore.app/Contents/Resources/THIRD_PARTY_NOTICES.txt` and `Runtime/licenses` |

Settings can clear generated thumbnails without deleting preferences, previews or retained external sessions. Close external documents before unmounting their volumes in Finder. Clearing the thumbnail cache does not disconnect servers or revoke external files.

## Migrate a development checkout

Quit the development app using **Quit and Keep Files Available**, then run this once from the checkout:

```sh
python3 scripts/migrate-state.py --from "$PWD/.runtime"
```

The migration copies preferences only if the destination has none, copies eligible thumbnail PNGs within 512 MiB, and records private legacy state roots so existing mounted sessions remain discoverable. It does not move/delete the old state, signal mount processes, or unmount external files. Existing destination preferences are never overwritten. Open the packaged app afterward.

## Build and package

```sh
scripts/bootstrap.sh
scripts/build-app.sh --release
# Place the matching rclone corresponding-source release ZIP in dist/ first.
scripts/package-release.sh
```

The public package gate requires the matching corresponding-source ZIP in `dist/` and verifies it against the notice inventory. Download that companion asset from the release, or regenerate it with `python3 scripts/collect-rclone-notices.py --collect --prepare --validate --package` on Apple Silicon with Command Line Tools. That source-kit build verifies an offline baseline and a modified LGPL library before sealing its manifest.

Dependencies are pinned in `scripts/runtime-lock.json` and verified before extraction. The package command writes a versioned ZIP, `SHA256SUMS` and `release-manifest.json` to ignored `dist/`. Without explicit signing credentials it produces an ad hoc signed beta.

For a future notarized release, set `FARSHORE_SIGN_IDENTITY` to an existing **Developer ID Application:** identity and `FARSHORE_NOTARY_PROFILE` to an existing `notarytool` keychain profile, then package. The pipeline signs nested code inside out with hardened runtime/timestamps, notarizes, staples and assesses the resulting app. The installed VideoLAN signature is verified before loading its different-team library; the host's library-validation exception is limited to this documented integration. Public signing still needs a real certificate and a clean Gatekeeper acceptance test.

## Report a problem

Use Settings → Copy redacted diagnostics, review the report and include it in a [GitHub issue](https://github.com/Awaisryk/farshore/issues). The report omits server names, usernames, paths, credentials and media capability URLs. Do not attach SSH configuration, private keys, private file listings or unrestricted logs.
