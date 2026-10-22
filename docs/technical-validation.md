# Technical validation

October 22, 2026. Measured observations below are separate from the PRD's targets.

## Environment

- Apple Silicon macOS 26.4; Swift 6.3 from Command Line Tools. Full Xcode absent and unavailable on this machine.
- Flutter 3.47.7 stable, commit `abaf9c523780a608bd46686fd5e53740a07077f8`, Dart 3.13.5; SDK local to the checkout.
- rclone 1.75.2 Darwin arm64. Official archive SHA-256 verified: `610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd`.
- System OpenSSH, Python 3.9, AppKit/Launch Services and ImageIO. No remote packages or configuration changes.

## Observed results

| Check | Observation | Result |
| --- | --- | --- |
| Native Flutter without Xcode | Direct assemble, CLT runner compile, strict ad hoc signature check; real Metal-rendered window, normal quit | Development pass |
| Release AOT without Xcode | Mode-isolated release assemble, optimized Swift host, native AOT exports, no JIT assets/entitlement; isolated native harness started the release engine and executed the actual Dart main | Local runtime pass |
| SSH discovery | Concrete aliases imported, includes traversed; no automatic connection | Pass for current config |
| Linux and server | Fresh strict-verification connections using existing authentication | Pass |
| Windows identity | Shared destination presented the other OS identity; bridge returned `host_identity_changed`, preserved trust | Correct rejection; Windows paths unvalidated |
| Native browser | Real server directory displayed five MP4/WAV files with selection and inspector; reviewed light narrow and dark wide layouts | Prototype pass |
| Native app discovery | Multiple installed compatible apps and OS default returned dynamically outside command sandbox | Pass |
| Image thumbnail | 87,303-byte remote PNG decoded into a 319×384 PNG; source metadata checked before/after caching | Pass |
| SFTP arbitrary offsets | Three 65,536-byte samples at beginning/middle/end of an existing 3,048,777-byte MP4 | Bounded payload pass |
| Read-only local NFS | Kernel mount flags include read-only/nodev/nosuid/nobrowse; listener observed only on 127.0.0.1 | Pass for mounting |
| Mounted remote reads | Existing 2,275,100-byte MP4: 1,024 bytes read at offsets 0, 1,137,550 and 2,274,076; follow-up one-byte read passed | Pass on recheck |
| Native mounted opening | NSWorkspace resolved current system default, QuickTime displayed the mounted file URL and 8-second video; frames visibly advanced after Play | Small-sample playback pass |
| Protected range stream | Real 2,275,100-byte MP4; 65,536-byte prefix/middle/suffix requests returned correct HTTP 206 and Content-Range in 1.070/1.063/1.073 seconds | Small-sample streaming pass |
| Embedded LibVLC | Actual native decoder produced 896×1184 video, duration 8,000 ms, clock advanced to 2,150 ms; 50% seek reached 4,000 ms and 90% seek reached 7,710 ms; stop acknowledged | Small-sample decoder/seeking pass |
| Full app integration | Published app opened real server folder; double-click launched the internal player, rendered real video with advancing clock, seek/volume controls and persistent Open With | Visual runtime pass |
| Large video/player seeks/cache pressure | No multi-gigabyte sample established in the bounded test folders; timeline seek observation incomplete due user interaction | **Not passed** |

Range sample command durations were 0.4701, 0.4882 and 0.4845 seconds. Returned payload totaled 196,608 bytes (6.45% of the source). Each used a fresh engine process. These are not warm-playback timings or exact encrypted wire-byte counts. The sample is much smaller than the proposed media-cache budget and cannot establish the large-video acceptance gate. Source-free detailed metrics live in ignored `.runtime/range-validation.json`.

## Initial macOS denial and recheck

Early tests returned EPERM for mounted file data even with a purely local NFS fixture. Kernel logs recorded `System Policy: cat(...) deny(1) file-read-data` and a direct unmount denial. Server logs showed metadata lookup without subsequent data reads. Disk Arbitration normal unmounts worked.

On a later explicit recheck, the local fixture read succeeded, then the real remote mounted video returned the three seek samples above. Native opening and visible playback followed. The exact permission/policy state change was not established; the agent did not change privacy settings. Do not describe the initial symptom as an SSH or server failure. The app includes local-network/network-volume usage descriptions, and Open requires a bounded actual read before launch.

The first remote directory-and-read probe was noticeably slow before completing. A follow-up single-byte read completed in approximately 0.6 seconds, but later cold probes again timed out at six seconds. NFS therefore remains an experimental external-app bridge. Internal LibVLC playback uses the protected HTTP range adapter over SSH and does not require NFS. Proper cold/warm large-file playback measurement remains required.

## Reproduce

```sh
scripts/bootstrap.sh
scripts/build-app.sh --run
python3 backend/farshore_bridge.py call hosts
python3 backend/farshore_bridge.py call list --params '{"hostId":"DISCOVERED_ID","path":"Videos"}'
python3 scripts/validate-read-path.py YOUR_ALIAS 'existing/video.mp4'
```

Inspect `backend/farshore_bridge.py` for exact argv construction. No credentials are exported. Private engine logs/preferences/cache/metrics stay under ignored `.runtime/`. New engine logs rotate at 4 MiB with two backups; media disk caching is off. Activity uses bounded structured engine stats for SFTP payload counts when available; these are not encrypted wire-byte measurements. The local stream tracks bytes served separately, and capability URLs are excluded from diagnostics.

## Remaining M0 gate

Validate a seekable video larger than the proposed media-cache budget in two applications chosen through discovery, beginning/middle/end player seeks, startup/resume latency, transferred-byte accounting, cache growth, concurrent handles, source replacement, interruption/recovery, Windows SFTP and persistent handler changes. Loopback NFS local-access exposure must be an explicit engine decision. The prototype is not release-ready.

## Resume/replay regression

The first player implementation conflated pause with end-of-file. Real-stream reproduction showed a paused clock holding at 1,405 ms and resuming to 2,904 ms, but after EOF the old seek-to-zero plus play sequence remained in VLC state 6 with its clock at 7,732 ms. This was an exhausted-input replay failure; the UI/main thread was responsive.

Native controls now distinguish resume from replay. Resume unpauses the existing input; replay stops the exhausted input before starting again. Ended state preserves the full timeline. Flutter uses explicit Pause/Resume/Replay actions, shows pending requests, confirms actual playback state, and surfaces command failure or timeout instead of silently accepting a no-op. The five added behavioral tests cover paused input preservation, EOF restart, buffering, acknowledged no-op and retry.

The durable native real-stream regression passed all five checks: paused clock 1,155→1,155 ms; Resume advanced to 1,905 ms; EOF reported 8,000/8,000 ms and position 1; Replay restarted and advanced to 655 ms; seeking from EOF reopened the input at 4,000 ms/position 0.5. Decoder stop acknowledged completion. Run `scripts/test-native-playback.sh PRIVATE_JSON` against a live private `prepare_media` response to repeat the optional CLT-only integration test; `--legacy-actions` also exercises the original failing button sequence. The script never prints its capability URL.

## UI performance

The running app at diagnosis used debug/JIT code: its bundle contained a roughly 42 MB `kernel_blob.bin`. The build script now defaults to optimized release AOT and Swift `-O`, using only Command Line Tools. The release engine initialized Metal/Impeller and executed the actual AOT Dart main in an isolated, invisible native smoke harness. Bundle verification checks the release mode, AOT snapshot exports, absence of JIT assets, and strict ad hoc signatures.

The release bundle was published and the old process restarted. The running release app reconnected to the same real server folder and a physical mouse click selected its prior folder with the inspector updated. Existing external NFS mount processes remained running across the restart. The current source passes 44 Flutter tests and analysis, including the original performance regressions.

Mouse selection originally shared a delayed tap recognizer with double-click opening, so a single click waited for the double-click deadline. Selection now responds on primary mouse pointer-down; activation still uses double-click. The widget regression observes selection within the first 16 ms pump, before the double-click timeout, and checks modifier selection in grid and list views.

Derived folder ordering is cached until its actual inputs change. Selection has its own notifier, appearance changes alone rebuild the app theme, unchanged status polls do not notify, and thumbnail completion updates the affected preview with frame-coalesced notifications. A synthetic model workload of 2,000 files, 200 selections and 1,200 view reads took 1.50–2.05 seconds before and 0.75–1.89 ms after in Flutter test/JIT. Name-property reads fell from 78,237,444 to 55,844, including the initial ordering. The regression asserts that repeated selection adds no name reads after ordering. These are model-work measurements, not end-to-end frame-rate or remote-listing timings.

A six-second idle native sample found the main thread waiting for events in about 97.5% of samples and the raster thread waiting in about 99.86%; active render stacks used Metal/Impeller. No native busy loop appeared. An idle sample cannot establish interaction frame times; wider live scrolling and large-folder profiling remain useful follow-up checks.

References: [Flutter build modes](https://docs.flutter.dev/testing/build-modes), [Flutter performance best practices](https://docs.flutter.dev/perf/best-practices).

## Favorite servers, absolute locations and video thumbnails

Server favorites survive a bridge reopen and preserve existing version-1 application preferences. Tests cover rapid serialized UI toggles, failed-save rollback, unchanged nonfavorite ordering and starring without connecting. Home remains the SSH-relative empty path; Root is `/`, and Go to folder (`⌘L`) preserves absolute `/data` and `/data2` paths. Narrow-window and breadcrumb/history regressions pass.

Real strict read-only one-level listings established these permissions; no mounts, remote writes or trust changes were needed:

| Host alias | `/` | `/data` | `/data2` | `/root` |
| --- | --- | --- | --- | --- |
| studio-server | Readable | Readable | Readable | Permission denied |
| studio-linux | Readable | Readable | Missing | Permission denied |

The AVFoundation helper generated a 290×384 PNG from the existing 2,275,100-byte SSH MP4 in 1.703 seconds, with 1,048,576 bytes served. A second lookup reused the PNG in 0.380 seconds, including a fresh metadata check, without additional video data. No media lease remained afterward. The generated frame was visually inspected.

Synthetic local native fixtures exercise range behavior beyond that small real sample: a 33,645,791-byte fast-start MP4 produced a 320×240 PNG using 3,145,728 bytes; a portrait MP4 with metadata after 32 MiB of padding produced a 240×320 PNG using 2,192,636 bytes, including a tail range. One-second timeout/cancellation, malformed URLs, unsupported inputs and no-overwrite checks passed. These fixtures verify bounded random reads, not multi-gigabyte playback acceptance.

Plain AVFoundation HTTP loading requested the full file and rejected valid shortened range responses. The implemented custom resource loader requests explicit cached 1 MiB blocks, so extraction does not require a full-file transfer. Native and bridge limits bound aggregate reads, request counts and runtime; playback revokes background leases. Source changes discard output, and an eviction race regression prevents returning zero-byte cached PNGs. Unsupported macOS codecs or budget failures retain placeholders. Repeat the optional native test with `scripts/test-native-video-thumbnail.sh [LOCAL_VIDEO]`; ffmpeg is used only to generate synthetic test fixtures when no local video is supplied, never by the app runtime.

All 25 backend tests and 44 Flutter tests passed, with clean analysis. The Flutter suite verifies that a 1,200-video directory requests only visible thumbnails.

## Native accessibility regression

Live validation caught a native SIGSEGV in Flutter's accessibility bridge during startup. Six crash reports shared the same null-parent stack in `AccessibilityBridge::CreateRemoveReparentedNodesUpdate`. A serialized-semantics regression reproduced an orphan node in the SDK's Material slider during incremental route updates. Each of Farshore's three sliders now uses a local `Overlay.wrap`, preserving Material rendering, keyboard controls and accessibility actions. The same regression then produced zero orphan nodes; dialog dragging/pop, browser discovery, favorite reordering, Root navigation and semantics disable/re-enable are covered. Accessibility stays enabled.

The rebuilt app survived live native AX reads after discovery and navigation. Its saved favorite server remained first after a full process restart, and filesystem Root displayed the actual remote `data`/`data2` entries. The workaround follows the [upstream Flutter report](https://github.com/flutter/flutter/issues/190357).

An identical isolated native harness distinguished the builds: the preserved failing release returned AX-tree errors and only two wrapper nodes; the fixed release exposed 50 startup nodes, 54 after fixture-host discovery, two while semantics were disabled and 54 when reenabled, then exited successfully. Its window stayed hidden and its fake bridge never accessed user preferences or SSH. Test-only KVC enables the engine's internal semantics state; the production runner does not use that test mechanism. Repeat with `scripts/test-native-accessibility.sh build/Farshore.app`.

Live validation also displayed all five remote MP4 thumbnails in the sample folder. The original absolute `/data2/media/output` location was then reopened in the final release, with the saved server favorite retained.

## Path launcher history

The launcher uses a global five-destination history, with logical host IDs and exact canonical remote paths. Backend regressions cover six-plus visits, deduplication and move-to-front ordering, persistence on reopen, distinct hosts sharing a hostname, Home versus Root, literal Unicode/whitespace/shell characters, legacy preferences, malformed-history preservation and failed-save rollback. Listing alone never updates history; the UI must explicitly record an accepted successful launcher navigation. A missing or failed listing cannot be recorded.

History, favorites and application choices use the same preference lock and atomic replacement. An independent concurrent-write check retained both a favorite change and a history visit, including an unrelated preference. Returned history records are copies, so a caller cannot mutate confirmed state through a response. All 30 backend tests pass.

All 55 Flutter tests pass with clean analysis. Launcher regressions cover the produced `/` character, text-field exclusion, Cmd+L while editing, repeated-key suppression, five host-labeled recent destinations, cross-server navigation, literal paths, failure/retry and cancellation while responses or route animations are pending. Actual player widgets verify that the native view remains mounted until stop acknowledgment, that navigation removes the player route beneath the launcher, and that failed stop leaves explicit dismissal available. A stable semantics container around each slider's existing local overlay also preserves accessibility when its enabled state changes beneath a dialog.

The isolated native release-AOT smoke test verifies `/` opening, all five recent rows, Up+Enter selecting the oldest destination, exactly one successful listing and history record, move-to-front ordering on reopening, Escape closing and semantics disable/re-enable with zero AX-tree errors. Its window stays hidden, and its fake bridge never touches user preferences or SSH. Repeat with `scripts/test-native-accessibility.sh build/Farshore.app --palette`.

Live validation was initially blocked by the locked Mac. After unlocking, the app was restarted and the launcher passed on-screen checks from Home and after clicking the embedded LibVLC video surface; see the final live validation below.

## App Home

Farshore now starts at its own Home destination, separate from a remote account's Home folder. Its server cards use imported SSH configuration and saved favorites; recent folders use the same persisted five-destination history as the launcher. Open-folder cards resume the actual current-session tabs. Home makes no automatic remote directory reads, and opening another host from Home preserves existing server tabs.

Model and integration regressions cover preserving entries, selections, filters and back/forward histories, exact-tab resume after a failed new connection, successful and failed Home server navigation, repeated clicks during loading, canceled/stale launcher responses, and Home keyboard isolation from hidden file actions. Recent-folder clicks open the exact saved host and literal path through the existing cancellable launcher, retaining retry on failure and recording only accepted success. A matching foreground error is cleared when its folder error becomes visible, avoiding duplicate or resurrected error banners.

Status requests coalesce while in flight and update their own listener rather than rebuilding the browser or theme. Home labels unknown measurements, last-success time and failed-refresh snapshots explicitly. Metrics distinguish mounted filesystem health, external-access protection, non-thumbnail preview leases, final PNG thumbnail usage and SFTP payload bytes for current filesystem sessions. The activity section displays up to three actual bridge messages, not an invented transfer history. A backend regression evicts a thumbnail and changes sessions during sampling; status completes from a consistent session snapshot, excludes thumbnail leases from preview counts and returns independent activity records.

Light/dark desktop and narrow Home fixture renders were inspected, with real font/icon assets and no overflow. The complete Flutter suite passes, including the existing serialized native-accessibility graph regressions; all 31 backend tests and static analysis pass. Release-AOT Home and launcher accessibility checks run against a hidden test window with a fake bridge, keeping user preferences and SSH untouched. Live validation followed after the Mac was unlocked.

The final Home release-AOT check passed: startup exposed 56 native accessibility nodes and 64 after fixture discovery, with all five recent paths and zero unsolicited directory listings. `/`, Up and Enter opened the fifth destination with exactly one listing and one history record. Native accessibility actions returned to Farshore Home, resumed the same folder without another listing, and returned Home again; disabling and reenabling semantics preserved the recent and resume actions with zero AX-tree errors. The test window stayed hidden. Repeat with `scripts/test-native-accessibility.sh build/Farshore.app --home`.

The complementary `--palette` check also passed on the same final bundle: 20 launcher accessibility nodes exposed all five recents, the fifth destination moved first after navigation, Escape closed the reopened launcher, and semantics rebuilding returned zero AX-tree errors. After the server-section adjustment below, both native checks passed again on the final published artifact. Its exact source passes all 82 Flutter tests and static analysis.

### Final live validation

The actual configuration contains 25 SSH aliases. Live review showed that rendering every server card pushed recent folders below the useful part of Home, so the section now starts with six favorites-first cards and a working Show all/Show fewer control. The regression checks 25 real model records, stable favorite order, both expansion states and zero bridge I/O.

The published release was restarted through Quit and Keep Files Available. Home displayed actual imported aliases, the saved server favorite and local cache/session status. A physical slash key opened the launcher; entering the previous absolute experiments path returned its 96 real entries. Clicking the native video surface and pressing slash opened the launcher above LibVLC. Escape returned to the existing player; submitting Root stopped and removed the player route before showing the real root listing. A failed path remained in the launcher for correction without changing the folder or history; retrying `/data2` succeeded.

After another full restart into the final compact Home build, the successful paths persisted and reopening the experiments recent moved it first. Home → Resume restored that exact folder and its selected video. Dark appearance was restored, and the final window was left on Home with the experiments tab available to resume. The running executable and AOT framework map to the current published bundle, launched after its build. All three preexisting external rclone processes remained running, and no new Farshore crash report appeared during validation.

## Thumbnail reliability in large folders

Live inspection found 104 videos among 106 entries in the video subfolder and 364 videos among 1,148 entries in its parent output folder. The missing previews were not simply unsupported codecs. A real baseline reproduced a process-group cleanup `PermissionError` after the first successful video; the HTTP handler then exited before releasing either read semaphore. The next six thumbnail requests failed without reading source bytes. Other files hit the single background-read gate while the previous response was still cleaning up; three of six parent samples timed out after exactly 2 MiB and roughly 10.5 seconds.

Cleanup now releases both read permits in nested `finally` blocks even when process cleanup fails. Owned-process cleanup has a short exit grace and bounded terminate/kill fallbacks; failed process-group signaling no longer aborts cleanup. A new background range waits up to one second for its predecessor, then rechecks revocation and deadline. The native loader has bounded busy-response retry, prompt classified transport failure and safe diagnostics. AVFoundation remains the decoder, with the existing 8 MiB aggregate, twelve-request, ten-second decode and fourteen-second lease limits; no FFmpeg runtime dependency was added.

Cold retesting passed all seven video-subfolder samples and all six parent samples. The former completed in 1.39–1.91 seconds, and the latter in 1.60–3.08 seconds, with only successful HTTP responses. The previously failing 310,602,962-byte sample produced a thumbnail after serving 2,321,618 bytes, rather than reading the whole file. Separate native tests recover from two injected busy responses, reject persistent busy/expired/malformed range responses with classified errors, retain URL validation and no-overwrite checks, and cancel at the one-second test deadline. Diagnostics never expose scoped capability URLs.

The UI no longer permanently caches transient null results. Ready, queued, loading, deferred, retryable and explicitly unsupported states have coalesced per-file listeners, bounded retries and explicit retry affordances. Verified cache hits work during playback. Folder generation covers the active tab's listed videos without scrolling or recursive discovery, with visible work prioritized, one video decoder, progress, cancellation and Retry missing. The regression suite includes a 300-video batch with zero broad browser rebuilds.

Final review added regressions for a new ready result reusing the same broken PNG path, stale image-decode callbacks, playback recovery after a failed status refresh, and thumbnail observers briefly remaining mounted after Home navigation. All 94 Flutter tests and 41 backend tests pass, with clean Flutter analysis. The signed native helper is staged and verified before atomic publication so a rebuild cannot overwrite a running helper.

The final release-AOT bundle passed the hidden native Home/accessibility regression with zero tree errors and no unsolicited startup listings. It was then restarted with external files kept available; the running executable and AOT framework map to the newly published bundle. Live inspection showed populated video previews throughout the visible experiments grid. Folder generation began at 25 of 61 ready there; subsequent user navigation opened the parent output folder and started its 364-video job, then opened the video subfolder with 12 of 104 ready and queued/generating states visible. A read-only audit observed nine new cached PNGs over 22 seconds, one native thumbnail worker, about 134 MiB of the 512 MiB cache in use, all three existing mounts alive and no new crashes. These observations verify live generation, not a claim that every file or codec has completed successfully.

## Saved workspace themes

The six themes cover three light and three dark palettes. Model tests validate text/muted/accent contrast of at least 4.5 on canvas, sidebar, surface, soft and selection colors; saved/reopened choices; rapid serialized writes; latest-failure rollback and recovery; late discovery fencing; and no broad model notifications or remote file reads during successful changes. Five new backend tests cover all theme IDs, legacy/unknown values, invalid requests, atomic-save failure and concurrent preference preservation.

Widget integration checks switch every theme while the picker stays open and verify the browser sidebar, Home text, app brightness and dialog surface all update. Escape closes the picker without leaving Home. A failed save shows an inline message and restores the previous theme. At 920×620 and 1.8 text scaling, the picker scrolls to the last choice and its Done action stays usable; a preexisting sidebar overflow was corrected by allowing the connection heading to wrap and retaining only the prototype title at larger text sizes. Home and paused/error player tests verify inherited role changes without preparing or replaying media again.

All 108 Flutter tests and 46 backend tests pass, with clean analysis. The signed release-AOT bundle passed the isolated native Home/accessibility check with zero tree errors and no startup directory listings. Live inspection found the user's existing folder-generation job at 150 of 364 ready, so the updated app was published atomically and the running session was left intact. The theme picker loads on the next app launch.

## Internal image, document, text and audio opening

The latest opening direction makes recognized image/document/text files internal by default and keeps external opening for unknown types or explicit Open With. Routing regressions exercise PNG, TXT, PDF and DOCX through Return into the file dialog, preserve selection after Escape and verify no external open/application-discovery call. The selected read-only text body still permits the global slash launcher; canceling the launcher returns to that same preview. Archive/unknown routing remains external. Twelve controller/dialog tests cover native open/close ordering, cancellation before preparation completes, late platform-view creation, failed cleanup acknowledgment, exact-route removal, retry, Escape, explicit fallback and compact light/dark layouts.

Twelve backend preview tests verify bounded direct SSH subprocess reads, private temporary files, before/after metadata, source changes, UTF-8 and BOM UTF-16, binary-text rejection, inert HTML, truncated text, size/disk/admission limits, cancel-before-register and in-flight cancellation, bounded tombstones, release retry, foreground thumbnail preemption, status/unmount protection and shutdown cleanup. The final backend suite passes all 58 tests. Existing preferences and thumbnail transport behavior remain covered.

The hidden QuickLookUI harness attaches and closes local PNG, PDF, RTF and DOCX fixtures; validates eight rejected path/type/size inputs; verifies inert factories, idempotent close and close-before-open; and checks slash, location and unmodified Escape forwarding while excluding modified/ordinary keys. Its window stays hidden. Quick Look attachment is not proof that every OS provider will render every document variant: the public API offers no provider-success callback, and Open With remains visible. Repeat with `scripts/test-native-preview.sh`.

The actual LibVLC audio session passed five checks with a muted synthetic eight-second WAV over a private local HTTP endpoint: pause held at 1,054 ms, resume advanced to 1,555 ms, EOF reported a complete 8,000 ms timeline, replay advanced to 555 ms, and seeking after EOF restarted at 4,000 ms. Stop acknowledged completion, all observed video dimensions were zero, and three fixture HTTP requests served 2,116,932 bytes across playback/replay/seeking. The widget regression verifies internal audio controls and stop-before-stream-release ordering. Repeat with `python3 tests/native/audio_playback_smoke.py`; it touches no SSH or user media.

All 127 Flutter tests pass and final analysis is clean. The final signed release-AOT bundle also passes the hidden native Home/accessibility test with zero tree errors. After the old thumbnail job was no longer active, the app was restarted through Quit and Keep Files Available. The previous output folder was reopened and its selected 634 KB PNG rendered visibly inside Farshore, with Open With alongside it. Clicking the native image and pressing slash opened the path launcher; Escape returned to the image, and Escape from the native image closed the viewer. The managed preview directory then contained zero preview files/bytes. The temporary filter was cleared while preserving the selected PNG and current Midnight theme.


## Standalone read-only beta and persistence

October 22, 2026: the final application uses a bundled CPython 3.13.17 runtime, rclone 1.75.2 and native helper, with explicit resource paths and state/cache outside the bundle. A relocation test copied the sealed app to a path containing spaces under /private/tmp, used a private empty SSH configuration, and successfully ran native runtime checks, bundled Python hosts/status, helper self-check and rclone version. Deep strict signature verification passed after copying. It created no visible window and required no checkout or user state.

All 151 Flutter regressions and 73 backend/packaging regressions pass, with clean Flutter analysis. Real subprocess tests cover helper exit/restart, malformed output, stale exits, bounded folder retries, cancellation, request bounds and no replay of file opens. Workspace tests cover lazy restoration, late startup/save races, favorite folders, cache controls and the explicit 32-tab limit. Native PNG/PDF/RTF/DOCX attachment/close and rejection/shortcut cases pass; signed VideoLAN audio playback passes pause/resume/EOF/replay/seek/stop with zero video frames. An unsigned VLC lookalike is rejected before dlopen.

The running development app was quit through its keep-files-available action. Copy-only migration preserved preferences, copied 1,200 completed thumbnail PNGs, and retained three existing external mount processes without moving their directories. The standalone beta loaded the selected Midnight theme, actual servers/recents and retained access counts, reopened the existing 1,148-entry folder through the global slash launcher, and saved its new favorite-folder choice. Settings and the bundled license page rendered in the actual app. After graceful quit/relaunch, the same tab appeared as a disconnected Saved folder; only the explicit Connect action began its SSH listing. User paths/hostnames are omitted from this public record.

The package remains ad hoc signed and unnotarized. These checks were run on Apple Silicon macOS 26.4; they do not prove older-system, quarantined-download, multi-gigabyte media, every external application, or sleep/wake acceptance.

The first public source commit also passed GitHub CI on the macOS 15 arm64 runner: pinned bootstrap, analysis, regression suites, standalone AOT build, deep signatures, hidden native Home and relocated runtime. This adds automated older-OS evidence while full interactive acceptance remains separate.
