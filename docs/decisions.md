# Engineering decisions

Recorded October 22, 2026. These choices implement a read-only macOS beta.

## Workspace themes

Six full palettes share named color roles across Home, the browser, dialogs and player controls: Shore, Deep Shore, Frost, Sand, Midnight and Orchid. The native logo stays consistent across themes. Palette text, muted text and accent colors meet a 4.5 contrast ratio on their main surfaces and selection backgrounds in the automated check. The theme picker previews each palette and applies choices immediately.

Stable theme IDs live in the existing version-1 preferences; missing or unrecognized saved IDs fall back to Shore. Theme writes share the preference lock and atomic replacement with favorites, recent folders and handlers. The UI serializes rapid choices, keeps the newest optimistic selection, rolls back only a failed latest choice to the last confirmed theme, and reports save failure beside the picker. Discovery cannot overwrite a newer explicit choice. Successful theme changes notify appearance only and perform no remote file reads. The browser repaints for an explicit appearance change while keeping the same model, navigator, tabs and decoder session.

## Internal opening for common files

The user requested that common formats, including PNG, open inside Farshore. Activation and Space now choose an internal file viewer for recognized image/document/text types, and the existing LibVLC player for audio/video. Unknown types use the existing external handler resolution. Open With stays explicit and available in every viewer, including unsupported/error states; failure does not automatically launch another program.

QuickLookUI supplies the macOS image/PDF/Office-family viewer without another package or full Xcode requirement. It consumes immutable private snapshots in the preview state directory, rather than live NFS files or arbitrary URLs. Its public API reports attachment and close, but has no renderer-readiness or provider-success callback; the OS handles provider-specific unsupported presentation. Text/source files use a bounded inert selectable text view, including HTML and Markdown. This is viewing, not remote editing.

The backend limits previews to two active/preparing snapshots, 128 MiB reserved temporary storage, 64 MiB per image, 32 MiB per document, a 512 KiB text prefix and a 30-second preparation deadline. It checks fresh source identity before/after reading, rejects binary text, uses argument arrays, and cancels only owned children. Request IDs cancel preparation even if release arrives before registration; the registry is bounded and expires old tombstones. Active previews protect host access and defer video thumbnail work.

Native preview factories are inert until Flutter records their view ID and explicitly opens them. Closing drains native open/close before acknowledging backend release, so late platform-view creation cannot start readers after a file was canceled. Unconfirmed cleanup retains the snapshot and blocks path navigation; explicit dismissal remains available. The native keyboard bridge forwards the app's path shortcut when a Quick Look provider owns focus. Audio suppresses video output and retains decoder-stop acknowledgment before releasing its stream lease.

## Framework and the no-Xcode constraint

Flutter was selected for its desktop rendering, lazy layouts, input model and future Windows/Linux targets. Both Flutter and React Native macOS ordinarily require full Xcode for their standard native builds. The user cannot install full Xcode on this machine.

A validated alternative uses Flutter's prebuilt macOS engine, direct `flutter assemble release_macos_bundle_flutter_assets`, and a small AppKit host compiled by Command Line Tools `swiftc`. The public `FlutterDartProject(precompiledDartBundle:)` API loads the standard framework resources. The real Flutter window rendered through Metal, browsed actual SSH files, and passed ad hoc signature verification. No web wrapper or private initializer is used; moving to the Mac mini is unnecessary for this development path.

The custom runner defaults to release AOT with an optimized Swift host; `--debug` explicitly opts into JIT. Mode-specific assemble outputs and build-time snapshot checks prevent stale debug assets from entering release bundles. Release code needs no JIT entitlement. An isolated native harness loaded the release engine and executed the actual AOT Dart entrypoint without full Xcode or a visible test window. The bundle now includes its Python runtime, rclone and native helper. Distribution signing/notarization and automatic updates remain future gates; the current beta uses ad hoc signatures and manual upgrades.

References: [Flutter desktop](https://docs.flutter.dev/platform-integration/desktop), [standard macOS tooling](https://docs.flutter.dev/platform-integration/macos/setup), [official macOS build targets](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/packages/flutter_tools/lib/src/build_system/targets/macos.dart), [React Native macOS](https://github.com/microsoft/react-native-macos).

## SSH and engine boundary

The Python bridge uses structured argument arrays and JSON listings. rclone delegates SFTP transport to system OpenSSH, preserving effective configuration and logical aliases. A direct subsystem preflight captures useful host-key errors; production operations do not run remote shell commands.

Strict verification, batch authentication, no automatic host-key updates and fresh connections are mandatory. Unknown or changed identities stop access. Existing trust records are preserved; first-use confirmation remains in the user's SSH tooling for this prototype.

rclone 1.75.2 `nfsmount` remains an experimental candidate. It exports only a selected file's containing directory, binds to loopback, and requires no remote setup or driver. Six simultaneous mounts are permitted. Local NFS is unauthenticated to other local processes even on loopback; evaluate that tradeoff before selecting the release engine.

The media disk cache is off, with 1 MiB buffers per handle and fixed 2 MiB read chunks. Full VFS caching supports sparse reads but its configured size is a soft limit while files are open, so it cannot alone establish a hard disk budget. Exact wire/read instrumentation, open-handle replacement detection and playback prioritization remain gates.

References: [rclone external SSH](https://rclone.org/sftp/#ssh), [experimental nfsmount](https://rclone.org/commands/rclone_nfsmount/), [NFS local-access model](https://rclone.org/commands/rclone_serve_nfs/).

## Native integration and lifecycle

Versioned newline JSON connects Flutter to a bounded worker pool. Native discovery, launching and the application chooser use AppKit without shell commands or a fixed player. Remembered extension choices change Farshore only; explicit System Default bypasses and can clear a stored rule.

Image workers fetch at most 32 MiB per source; native decoding rejects more than 80 million source pixels. PNG output has a 512 MiB LRU budget. Temporary inputs are unique per job and separate from final cache entries. Cache hits and eviction share a lock; timestamp updates never recreate an evicted PNG as an empty file.

Video thumbnails use AVFoundation in the separate native helper. A custom resource loader translates decoder reads into cached 1 MiB HTTP ranges, with an 8 MiB aggregate request budget, at most 12 HTTP requests, a 10-second decode deadline and a 14-second lease lifetime. The bridge also enforces byte/request limits and permits one background read, reserving capacity for playback; starting playback revokes background leases. Source identity is checked before and after decoding. The loader accepts only the exact protected loopback resource, disables redirects, proxies, credentials, cookies and HTTP caching, and forbids embedded external media references. Unsupported formats or budget failures retain placeholders.

Thumbnail results distinguish ready, deferred, retryable and explicitly unsupported outcomes. Temporary transport, cleanup, timeout and source-change failures are never permanent negative cache entries. A ready cache lookup using supplied entry metadata must match an actual successful directory listing before bypassing remote stat; uncached decode still verifies source identity. Duplicate work and busy video workers defer without occupying bridge worker threads. Only one video decoder runs per UI scheduler, and visible requests take priority over optional folder-wide generation.

Read cleanup releases every acquired stream permit even when process signaling fails. Owned stream children receive bounded graceful/terminate/kill cleanup, with an owned-process fallback when process-group signaling is denied. A background read waits briefly for the preceding read's cleanup instead of turning an ordinary sequential request into a decoder failure; the native loader also retries a bounded number of busy responses inside its existing deadline and request budget. Safe native failure diagnostics contain stages, numeric status/counters and fixed reasons, never capability URLs.

Folder-wide generation uses only the active tab's already listed video entries, with ready/total progress, cancel remaining work and retry missing. It does not recurse into folders. At most three automatic attempts and bounded deferral handling prevent uncontrolled polling; playback deferrals resume when confirmed idle. Thumbnail state and batch progress have separate coalesced listeners so decoding does not rebuild the browser, sort directory entries or reset its theme. Helper builds compile and verify a staged executable before atomic publication, preserving active helper processes.

Favorite server IDs are an additive field in version-1 local preferences; existing application choices and unknown settings survive migration. Saves replace the preferences atomically, and failed favorite saves preserve confirmed state. The UI keeps favorite servers first and preserves SSH-config order within each group. Home is the empty relative path; Root is `/`. Absolute paths remain absolute through listing, previews and opening, subject to server permissions.

The path launcher's five recent destinations are global, keyed by logical host ID and canonical remote path, with the most recent first. They are another additive version-1 preference. Listing a folder does not record it: the UI explicitly records a visit after accepting a successful launcher navigation, excluding failed, canceled and stale attempts. Reopening a destination deduplicates and moves it to the front; Home and Root remain distinct. A failed preference save keeps confirmed history and does not undo navigation.

Farshore Home is an app destination separate from a server's SSH home directory. It starts without remote reads, keeps existing tabs, selections, filters and directory histories, and resumes cached workspaces without reconnecting. Opening a new server from Home preserves existing server tabs. Recent-folder actions share the path launcher's host identity, acceptance, retry and cancellation flow. A view epoch prevents responses accepted after a return to Home from bringing an old navigation back to the foreground.

Home shows configuration and current session data, rather than inferred availability or invented activity: favorite servers, five launcher destinations, open folders, final thumbnail PNG usage, mount states, protected external access, preview leases, scoped filesystem payload reads and the last three actual opening events. A coalesced status request records last-success time and failures separately from foreground errors; stale data stays labeled. Session snapshots are copied under the bridge lock, and thumbnail eviction during a status sample is tolerated. Imported SSH aliases are not described as online, and session counters are not a lifetime transfer history.

Home initially shows six favorites-first server cards, with a local Show all/Show fewer control. All imported aliases remain in the sidebar. This keeps recent paths visible for the user's 25-alias configuration without hiding the configured count or starting additional connections.

Mounts are independent of tabs. A registry recovers them conservatively across bridge restarts, and pending external opens protect the mount before native launching begins. Recovered sessions are assumed to have readers. Quit offers cancellation or keeping remote files available. Normal Disk Arbitration unmounts never force external readers off a volume.

## Deferred

Manual host entry, advanced handler scopes, downloads/uploads, safe file management and external editing remain separate work. No remote writes are enabled. The project source uses MIT and is published at Awaisryk/farshore. Read-only recovery, favorite folders and workspace/cache settings are implemented for the beta.

## Embedded VideoLAN playback

The user requested in-app playback with Open With as a fallback. The native plugin dynamically loads LibVLC 3 from the installed VLC application, resolved by bundle identifier. It renders into a Flutter AppKit platform view. Controls use a method channel; stop acknowledges actual decoder shutdown before the bridge releases access. Missing engines, unsupported files and decode failures retain the explicit external-opening choice.

Internal playback uses a protected single-resource HTTP range adapter on 127.0.0.1, backed by bounded rclone/OpenSSH reads. This avoids intermittent NFS stalls for the internal player while retaining mounted paths for ordinary external apps. Routes contain random scoped capabilities, no filenames or SSH credentials; only GET/HEAD are accepted, no directories are exposed, source metadata is validated per request, and closing a lease revokes access and cancels child reads. Request workers, active reads, buffering and timeouts are bounded. The adapter makes no full-copy prerequisite or permanent media cache.

The installed VLC version is 3.0.23. LibVLC's public API is [LGPL-2.1-or-later](https://raw.githubusercontent.com/videolan/vlc/3.0.23/include/vlc/libvlc.h); VLC desktop and parts of its plugin set use GPL licensing. The installed plugins must not all be described as LGPL. This prototype redistributes no VLC binaries; a bundled distribution needs an exact module/dependency and source/notice compliance review.

## Recovery, saved workspace and local state

Only idempotent reads (hosts, status, list, recent paths and diagnostics) can replay after a bridge exit. Folder reads also retry transient connection/time-out failures twice with bounded delays and cancellation; authentication and host identity failures stop. Generation-tagged pending requests ignore late exits from an old helper. Opening applications, allocating media leases and preference mutations are never automatically replayed.

Versioned workspace preferences preserve logical host IDs and paths, active tab/Home and display choices. Startup restores metadata without remote listing, mounts or media access. Explicit Resume connects a saved folder; unavailable aliases retain a recoverable placeholder. Coalesced writes serialize atomic saves and protect explicit user changes from late startup hydration. Graceful native quit waits up to four seconds for a workspace flush after any external-access confirmation.

Preferences and retained-session metadata live in Application Support/Farshore; generated thumbnails live in Caches/Farshore. Settings limits thumbnails to 128 MiB–2 GiB, can remove finished PNGs without touching active previews/external mounts, and copies an allowlisted diagnostics snapshot without server names, paths, keys or capability URLs. Development-state migration copies preferences and bounded thumbnails without overwriting existing settings, moving mounts or signaling their processes.
