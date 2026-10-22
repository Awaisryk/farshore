# Implementation status

October 22, 2026. Farshore 0.2.0 targets a read-only Apple Silicon macOS beta, with a native release AOT runner built using Command Line Tools instead of full Xcode.

| Area | Current state | Remaining gate |
| --- | --- | --- |
| Browser | Real SSH discovery, strict verification, tabs, Home/Root/direct paths, global `/` launcher, grid/list/gallery, filters/sort, hidden files, selection and inspector | Wider real-folder, keyboard and VoiceOver coverage |
| Workspace | Saved tabs and display settings, lazy explicit resume, favorite servers/folders, five host-aware recent paths, six themes | Broader upgrade and older-system coverage |
| Opening | Native image/PDF/Office previews, bounded selectable text, streamed video/audio, explicit Open With and remembered app choices | Provider/codec matrix, moved/missing applications, wider external-app acceptance |
| Thumbnails | Progressive visible previews and nonrecursive folder-wide video generation; bounded workers, retries, cancellation and cache controls | Some formats exceed macOS codec/read budgets and retain placeholders |
| Recovery | Restartable bridge, bounded/cancellable folder retries, trust/authentication failures stop; sanitized diagnostics | Real sleep/wake and prolonged outage acceptance |
| Packaging | Standalone pinned Python/rclone/native helper, atomic publication, copy-only state migration, notices and versioned checksum packages | Developer ID signing/notarization and clean Gatekeeper download acceptance |
| Remote operations | Read-only browsing and previews | Explicit transfers and all writes remain separate PRD gates |

The Home page uses actual configured servers, recent folders, resumable tabs, cache usage and retained access/activity. It initially shows six favorites-first server cards and expands to all aliases without network activity. Saved workspaces also restore without remote activity until Resume/Connect is chosen.

Application preferences and retained-session metadata use Application Support/Farshore. Generated thumbnail PNGs use Caches/Farshore; Settings changes the 128 MiB–2 GiB budget or clears completed images without touching open previews or external mounts. Existing SSH credentials stay in OpenSSH tooling. No telemetry or automatic uploads are enabled.

Validation: **151 Flutter tests, 73 backend/packaging tests and clean Flutter analysis**. This includes real subprocess crash/restart, bounded retry/cancel, malformed output, no replay of file opens, stale process exits, lazy workspace restoration, preference races, settings/cache operations and redacted diagnostics. Native package checks and their exact evidence are recorded in [technical validation](technical-validation.md).

Earlier live validation passed real root/data-directory browsing, progressive image/video thumbnails, bounded SSH media ranges, internal video rendering and a 634 KB remote PNG. Native PNG/PDF/RTF/DOCX attachment/close and muted audio decoding passed. Thumbnail diagnosis covered 13 cold real-video samples, including a 310 MB file using about 2.3 MB of source reads. These samples do not establish multi-gigabyte playback or every codec/provider.

Loopback NFS remains experimental and can stall on cold mounted reads. Its local unauthenticated access model, multi-gigabyte media, two real external applications, source changes, sleep/wake and sustained cache pressure still need full acceptance. No remote writes or transfers are exposed. This beta is ad hoc signed and not notarized; only Apple Silicon macOS 26.4 has been validated locally. See [production readiness](production-readiness.md) and [release instructions](releases.md).
