# Production readiness

October 22, 2026. The release target is a **read-only Apple Silicon macOS beta**. Remote writes, explicit transfers and the full PRD remain outside this beta.

## Completed for the beta

- Native app icon, sidebar mark, SVG logo and browser assets; package versions derive from `pubspec.yaml`.
- Release AOT runner built with Command Line Tools, plus bundled pinned Python, rclone and native helper. State uses Application Support and Caches; no checkout path is embedded in the release.
- Bounded read recovery, helper restart, visible retry/cancel, strict host-key failures and no replay of application opens or mutations.
- Lazy saved workspace, favorite servers/folders, six themes, thumbnail budget/clear controls and user-triggered redacted diagnostics.
- Internal image/document/text previews and audio/video streaming with explicit Open With fallback. Installed VLC is optional and authenticated before loading; VLC binaries are not shipped.
- Atomic build publication, copy-only development-state migration, exact dependency provenance/notices, versioned ZIP/checksum manifest, MIT project license and CI.

## Remaining gates

| Gate | Status |
| --- | --- |
| Developer ID signing and notarization | No Developer ID Application identity is available on this machine. This beta is ad hoc signed, unnotarized and may be blocked by Gatekeeper. The packaging pipeline accepts an explicit Developer ID identity and notary profile for a later release. A quarantined clean-Mac download test remains open. |
| Supported operating systems | Validated locally on Apple Silicon macOS 26.4. The bundle's `12.0` deployment metadata does not prove older-system compatibility. GitHub CI also passes build/runtime, hidden Home and relocated-runtime checks on macOS 15 arm64. Full interactive older-system and Intel acceptance remains open. |
| External-file access engine | Loopback NFS is experimental, unauthenticated to local processes and has shown cold-read stalls. External sessions remain protected while files may be open; users close external readers and unmount in Finder. Internal playback uses protected scoped HTTP ranges instead. |
| Wider media acceptance | Multi-gigabyte cold playback, beginning/middle/end seeks, two real external applications, source changes, sleep/wake and sustained cache pressure still require the full PRD acceptance pass. Current automated recovery, preview and small media tests do not establish those broader claims. |
| Accessibility coverage | Native tree and keyboard regressions pass. A complete VoiceOver, text-scaling, contrast and supported-system review is still required. |
| Updates | Manual replacement of the app retains Application Support/Caches. Automatic signed updates are not implemented. |

No telemetry or crash upload is enabled. Settings copies a redacted report only when requested. SSH credentials remain managed by existing OpenSSH tooling. Preview snapshots are bounded and removed on acknowledged close; generated thumbnail PNGs remain until budget eviction or explicit clearing.

See [release instructions](releases.md), [validation evidence](technical-validation.md), [dependency inventory](dependencies.md) and [PRD](../PRD.md).
