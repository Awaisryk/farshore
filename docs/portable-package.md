# Portable macOS beta

The Apple Silicon app includes Python, rclone, the native helper and backend under `Contents/Resources/Runtime`. Running the installed app requires neither this checkout nor Xcode/Python/Homebrew. System OpenSSH continues to use your existing SSH configuration, keys, agent and known-host trust. Optional embedded video/audio requires an official, intact VLC 3 installation; Open With remains available.

Persistent settings and workspace live in `~/Library/Application Support/Farshore`. Thumbnail cache lives in `~/Library/Caches/Farshore`; bounded document snapshots remain in the private state directory until their readers close. Copying or upgrading the app does not relocate mounted folders or terminate external applications' filesystem sessions.

## Migrating a checkout installation

Quit the old Farshore app using **Quit and Keep Files Available** if prompted. Then run the one-time, copy-only migration with a build-time Python interpreter:

```sh
python3 scripts/migrate-state.py --from "$PWD/.runtime"
```

Existing destination preferences and cached files are preserved. Only bounded preferences JSON and completed PNG thumbnails are copied; preview temporary files and mounts are never copied, deleted or unmounted. The private `legacy-states.json` remembers the original mount-registry location. The portable backend adopts only validated, already-mounted live sessions from those explicit legacy roots and keeps their original paths protected. Keep the old `.runtime/mounts` directories until you have closed their external files and ejected those volumes in Finder.

The migration is optional for a fresh installation. For an isolated test, supply `--state` and `--cache` to point to temporary directories. Explicit `FARSHORE_STATE`, `FARSHORE_CACHE` and `FARSHORE_LEGACY_STATES` overrides are also available to developers; legacy roots are colon-separated absolute private directories. Never share those state directories with another account.

## Build and validate

```sh
scripts/bootstrap.sh
scripts/build-app.sh --release
python3 scripts/test-portable-app.py build/Farshore.app
scripts/test-vlc-identity.sh
python3 -m unittest tests/test_migrate_state.py
scripts/package-release.sh
```

The relocated smoke copies the sealed app to `/private/tmp`, uses a private empty SSH configuration and private state/cache, starts no window, and checks the native runtime, bundled Python/backend, helper and rclone. It verifies checkout-independent bootstrapping without contacting a remote host. Normal interactive behavior is validated separately.

## Distribution signing

Default artifacts are explicitly **ad-hoc signed, unnotarized betas**. Their release manifest records this status, the tested macOS version, deployment target, pinned upstream runtime digests and ZIP SHA-256. This local build has been tested on macOS 26.4 arm64; the macOS 12.0 deployment target does not mean every older version has been tested.

When a distribution certificate and notarization tools/profile are provisioned, the same commands support:

```sh
export FARSHORE_SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)'
export FARSHORE_NOTARY_PROFILE='your-preconfigured-notary-profile'
scripts/build-app.sh --release
scripts/package-release.sh
```

The pipeline signs nested Python extensions, executables and frameworks before the host, enables hardened runtime for Developer ID signing, submits the ZIP, staples the accepted ticket, verifies Gatekeeper assessment and rebuilds the final ZIP/checksum. It never selects an available certificate automatically or exports keys. `notarytool`/`stapler` are required only for that configured path; the ordinary build uses Command Line Tools and does not require full Xcode. No notarization is claimed when credentials or tooling are absent.

The host deliberately permits loading a library from another signing team so that separately installed VideoLAN works. Before `dlopen`, Security.framework verifies the full VLC bundle/nested code against the official VideoLAN Developer ID requirement and constrains loaded paths to that bundle. An unsigned or modified application fails closed to Open With.
