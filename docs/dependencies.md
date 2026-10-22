# Dependency inventory

Portable beta inventory, October 22, 2026. Farshore is MIT licensed. Bundled runtime downloads are pinned in [`scripts/runtime-lock.json`](../scripts/runtime-lock.json); a release is Apple Silicon only.

| Component | Version | License / source | Use |
| --- | --- | --- | --- |
| Flutter | 3.47.7, `abaf9c523780a608bd46686fd5e53740a07077f8` | [BSD-3-Clause](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE), engine third-party notices | Native interface/engine |
| Dart | 3.13.5 from Flutter SDK | [BSD-3-Clause and notices](https://github.com/dart-lang/sdk/blob/main/LICENSE) | Compilation/runtime |
| rclone | 1.75.2 Darwin arm64 | [MIT](https://github.com/rclone/rclone/blob/v1.75.2/COPYING), transitive notices | SFTP and experimental NFS bridge |
| OpenSSH | System | [BSD-style collection](https://www.openssh.com/bsd.html) | SSH identity/authentication/configuration |
| Python | Bundled CPython 3.13.17, Astral standalone build 20261021 | [Python license](https://docs.python.org/3/license.html), exact upstream dependency licenses and build metadata | Local bridge, standard library only; no end-user Python or CLT installation required |
| AppKit, ImageIO, AVFoundation, QuickLookUI, Swift | System CLT/SDK | Apple SDK/toolchain terms | Native host/integration, image/video thumbnail decoding and embedded image/document previews |
| LibVLC / VLC | Optional installed VLC 3, tested 3.0.23 | [LibVLC LGPL-2.1-or-later](https://raw.githubusercontent.com/videolan/vlc/3.0.23/include/vlc/libvlc.h); independently installed plugins have their own licenses | Embedded video/audio; no VLC code is redistributed. Before loading, Security.framework verifies the intact application and nested code against the VideoLAN Developer ID team `75GAHG3SZQ` and identifier `org.videolan.vlc` |

No third-party Flutter runtime packages are used. Test dependency versions are captured in `pubspec.lock`. OpenSSH and Apple frameworks remain system components, not bundled copies. Downloaded archives, SDKs and builds remain ignored artifacts.

The official immutable [Astral release 20261021](https://github.com/astral-sh/python-build-standalone/releases/tag/20261021) is pinned to source commit `0c5e581b54a4736cdbbe68bdd6d7e571a1dca11e`. The arm64 install-only stripped archive SHA-256 is `8dc60610a82f1e73be7faf964383e02520f95f6e39592a5c37c3809f5a7b798e`; the matching full archive used for licenses/PYTHON.json is `3ccb423f96990a6ac6a10e23052ba6c70144117559af097cd0c0305939dc015b`. Both are verified before extraction. The package omits pip, ensurepip and IDLE; it preserves the upstream standard-library and dependency license texts plus machine-readable build metadata. Some upstream license texts describe optional components not used by Farshore.

The rclone archive is downloaded from the official versioned endpoint and verified against SHA-256 `610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd`. Its MIT license and collected dependency notices are included. Flutter's pinned SDK supplies the complete engine `sky_engine/LICENSE`, Dart license, Material Icons license and generated application `NOTICES.Z`. The latter is gzip decoded into the consolidated notice file.

Every bundle exposes `Contents/Resources/THIRD_PARTY_NOTICES.txt` to the application license page through `FARSHORE_NOTICES`, with raw texts in `Contents/Resources/Runtime/licenses`. The default local package is an **ad-hoc signed, unnotarized beta**. A configured `Developer ID Application` identity and notarization profile enable the conditional distribution pipeline; an Apple Development certificate is not used for public distribution. The deployment target is macOS 12.0, while actual local validation has been on macOS 26.4 arm64; older systems are not claimed as tested.
