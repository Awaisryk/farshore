# Farshore Product Requirements

Version 1.0 · October 22, 2026 · Status: implementation brief

Farshore is a desktop file browser for machines already accessible through SSH. It combines a carefully designed media browser with a local filesystem bridge, so remote files can open in user-selected desktop applications without a separate file-sharing service on the server.

The central product promise is simple: choose an existing SSH host, browse a beautiful grid of files, preview an item, and open it in the application you prefer. Videos should begin playing while data arrives, and seeking should request the relevant parts of the remote file. A complete download must be a deliberate action rather than a hidden prerequisite imposed by the browser.

## 1 Product context

The user regularly connects to `studio-linux`, `studio-windows`, and `studio-server` using SSH terminals. They want an equally convenient graphical way to inspect files, particularly images and videos.

Cyberduck was installed and configured during the preceding session. Its list-oriented browsing and download-on-double-click workflow did not meet the need. A successful image Quick Look test did not validate video streaming or the intended media browsing experience. Do not repeat that incomplete validation.

The user chose to build a dedicated application using Flutter or React Native. They explicitly rejected installing another remote service as the solution and clarified that all access should use their existing SSH connections. They also rejected a fixed media-player action: external applications must be discoverable and configurable.

### Confirmed user requirements

| Requirement | Meaning |
| --- | --- |
| Build our own application | Own the interface and workflow; reuse suitable open-source components underneath |
| Flutter or React Native | Evaluate these frameworks for a desktop product |
| Superb visual design | The interface must be a primary product strength, with thoughtful interaction and performance |
| Existing SSH connections | Reuse aliases, authentication, and host verification rather than introduce separate remote accounts |
| No remote service setup | No Samba, remote HTTP server, agent, daemon, or additional remote package requirement |
| Visual browsing | Thumbnail grid and meaningful previews, alongside useful alternative views |
| Configurable applications | Users choose which apps open different types of files |
| Remote playback | Media can be read incrementally, including seeking, rather than always downloading first |

### Proposed choices to validate

The following choices are recommendations, not additional user commitments:

- Flutter for the interface, with a native macOS integration layer.
- macOS as the first client platform; Windows and Linux clients are later work.
- An existing open-source engine for the first filesystem bridge.
- A read-only technical prototype before introducing writes and file-management operations.
- An open-source project and dependency policy. The user expressed interest in open-source solutions; public publication and the project's license remain undecided.

## 2 Goals and scope

The first release should make routine remote media inspection feel like a capable local desktop browser. Users should connect with familiar host names, navigate folders quickly, recognize files visually, and use their existing applications.

Success depends on three capabilities working together: a fast visual browser, reliable partial remote reads, and normal operating-system application opening. A beautiful interface that downloads every video before launch does not satisfy the product. A filesystem mount without the intended browsing experience also falls short.

### First release scope

SSH host discovery and manual connection, browsing with tabs and favorites, grid/list/gallery views, image and common video previews, configurable application associations, mounted paths for external apps, explicit transfers, cache controls, and visible connection recovery.

Rename, create folder, upload, copy, and deletion are planned after the read path is proven. Each operation must have clear completion and recovery semantics before release. External editing is gated separately because some applications save through temporary files, renames, locks, and sidecar files.

### Outside the first release

Cloud storage providers, remote desktop, terminal replacement, public links, multi-user collaboration, transcoding infrastructure, media-library cataloging, automatic two-way synchronization, and a newly written cryptographic or SSH implementation. Mobile clients and App Store distribution are not initial requirements.

The product is a general file browser with strong media support. It should not become limited to designated media directories or to one model-generation application.

## 3 Users and workflows

The initial user is a technically capable Mac user managing Linux and Windows machines through SSH. They already have authentication working and want minimal additional configuration.

### Browse and inspect

1. Launch Farshore and select a saved SSH alias.
2. Open the home directory or a favorite path.
3. See filenames and placeholders immediately; thumbnails populate without blocking navigation.
4. Resize the thumbnail grid, filter by filename or type, and inspect the selected item in a preview pane.
5. Use Space for a larger preview and arrow keys to move through adjacent files.

### Play a video inside Farshore

Implementation direction confirmed October 22, 2026: videos should play inside Farshore using VideoLAN's LibVLC, with Open With available as an explicit fallback. This supersedes the original default double-click behavior for videos. Application discovery and configurable external handlers remain required.

Additional opening direction confirmed October 22, 2026: common image, document, text/source and audio formats should also open inside Farshore by default. External opening remains available for unknown or difficult types and as an explicit choice from each viewer. Preview failures should offer a useful fallback rather than launch another application automatically. Bounded temporary local copies are appropriate for image/document previews; large audio/video files retain streaming.

1. Double-click a video or select Play in Farshore.
2. Begin playback through an SSH-backed read adapter with play/pause, seeking, and volume controls.
3. Keep Open With available for unsupported media, a missing engine, or a user preference for an external app.
4. Stop the decoder before releasing its read access when the preview closes.

A protected local HTTP range endpoint is appropriate for this internal player; it does not replace the mounted-file requirement for ordinary external applications. No remote HTTP service is introduced.

### Open a video in a preferred external player

1. Select a remote video and invoke Open With.
2. Resolve the applicable user rule or operating-system default.
3. Open the corresponding mounted file path in the selected application.
4. Read enough data to begin playback; seeking issues new reads at the requested positions.
5. Keep Farshore's connection and file handles alive while the external app needs them.

No permanent copy should appear in Downloads as a side effect of Open. Some formats and applications may read much or all of a file. The interface must expose transfer and cache behavior honestly rather than promise zero downloading.

### Choose or change an application

The context menu offers Open With, including compatible installed apps, the system default, recently used handlers, and Choose Application. Users can apply a selection once, remember it for the file type, or create an advanced handler rule.

### Recover from a network interruption

An interruption preserves the current location, selection, cached directory listing, and scroll position. The interface distinguishes stale cached metadata from current server information. Recovery attempts have a visible status and cancel control. Unsafe writes are never replayed blindly.

## 4 Visual and interaction direction

Farshore should feel like a premium desktop tool with a quiet nautical identity. The name suggests bringing distant files within reach; avoid literal ship illustrations or decorative effects that interfere with work.

### Layout

- A restrained sidebar for hosts, connection state, favorites, and recent locations.
- A tab strip for browsing different hosts or directories without losing context.
- A compact toolbar with back/forward, breadcrumbs, search, view controls, and thumbnail size.
- A virtualized content area supporting grid, detailed list, and gallery presentation.
- A resizable inspector for preview, dimensions, duration, size, modification time, permissions, and the configured opening application.
- A collapsible activity area for transfers, buffering, connection recovery, and actionable errors.

### Visual system

Use warm light surfaces and deep neutral dark surfaces, a restrained sea-glass or blue-green accent, high-quality system typography, consistent spacing, and subtle elevation. Match platform conventions for focus, selection, menus, window behavior, and shortcuts. The palette is a design starting point rather than a fixed brand decision.

Content should dominate. Images and videos deserve generous presentation, correct aspect ratios, and filenames that remain legible. Provide adjustable density; never force large decorative cards on folders containing thousands of files.

Create tokens for spacing, typography, color, border radius, focus rings, selection, and motion before spreading style values across widgets. Use original vector or code-drawn iconography only where system icons are insufficient. Placeholder states should preserve layout while content arrives.

### Interaction requirements

Support keyboard navigation, multi-selection, Shift selection, context menus, type-to-select, clipboard paths, drag operations with explicit semantics, and standard window resizing. Hover effects and animation should be subtle and respect reduced-motion preferences. Errors belong near the affected content or operation, not only in transient notifications.

Grid thumbnails must appear progressively. Clicking another folder cancels or deprioritizes work for the old folder. Loading a thumbnail must not freeze selection, scrolling, or the entire file list.

All controls need accessible labels, meaningful focus order, adequate contrast, and support for text scaling and screen readers. Light and dark modes must be designed and reviewed independently.

## 5 SSH connection requirements

### Connection sources

Import usable hosts from the existing OpenSSH configuration. Display the alias prominently; do not substitute an IP address as the user's primary identity for a host. Allow manual host creation without requiring users to edit SSH configuration.

Honor relevant effective SSH configuration, including HostName, User, Port, IdentityFile, IdentitiesOnly, agent authentication, HostKeyAlias, ProxyJump or ProxyCommand where configured, and included configuration files. Prefer executing the system OpenSSH client when this gives more faithful behavior than duplicating configuration parsing. Do not claim complete OpenSSH compatibility until tested.

### Host identity

Host verification is mandatory. Never resolve a failure by disabling StrictHostKeyChecking, clearing known_hosts, or accepting a changed identity automatically. First-use prompts show the alias, effective destination, algorithm, and fingerprint.

The current Windows and server aliases share an IP address and present different operating-system identities at different times. `studio-server` uses HostKeyAlias in the current configuration. Treat that as an important integration case: saved endpoints cannot be keyed only by IP address. A Windows alias encountering the Linux host identity must produce a useful explanation and preserve the existing trust records.

### Session management

Maintain connection state per host, use bounded connection/channel pools, keep sessions alive while needed, and back off reconnect attempts. Separate directory reads, thumbnails, and external playback so background preview work cannot consume every connection. Do not alter the user's global SSH settings to make the app work.

No passwords, private key contents, or tokens may be written to application logs, settings exports, or repository files. Use the operating-system credential store for new secrets when needed.

## 6 Browsing and previews

### Directory navigation

Support home, parent, root where permitted, breadcrumbs, direct path entry, back/forward history, hidden files, sorting, filtering, and favorite paths per host. Remote permission failures must identify the inaccessible path without discarding the rest of the browser session.

Search in the first release means filtering the loaded directory by name and type. Recursive search is separate and must not be implied by the interface. File metadata is cached with an explicit freshness strategy and can be refreshed manually.

Preserve case-sensitive remote filenames even when the local filesystem behaves differently. Test spaces, Unicode, quotes, long names, symlinks, broken symlinks, and Windows SFTP path conventions. Do not assume every server uses a Linux home-directory structure.

### Thumbnails

Generate image and video thumbnails locally using bytes obtained through SSH. No remote thumbnail agent or remote ffmpeg installation is required. Existing remote tools may become an opt-in optimization later; they are not a baseline dependency.

Prioritize visible items and a small nearby prefetch region. Cache thumbnails using a key that includes logical host identity, canonical remote path, file size, and modification time. Invalidate changed files and provide a refresh action for unreliable server timestamps.

Thumbnail generation must have concurrency, byte, time, and disk budgets. Some image formats require complete reads; some video containers require metadata near the end of a file. Support range reads through the same backend and track their costs. A preview failure should leave a useful file icon and filename rather than stall the folder.

Never download every large video completely merely to fill a folder grid. Cancel requests when items leave the work queue, and distinguish unsupported media from connectivity failures.

### Preview behavior

Provide inline image preview, common video/audio preview where supported, and basic text preview with size limits. Unsupported codecs should preserve the Open With workflow. The initial release does not promise to decode every format internally.

Opening or decoding untrusted media should happen in an isolated worker or platform facility where practical. Keep expensive decoding outside the interface thread. Avoid changing remote metadata or writing thumbnail files to the server.

## 7 Application discovery and associations

There must be no hard-coded primary player, hard-coded application path, or static Play in VLC control as the general opening model.

### Handler resolution

Common supported files default to the in-app viewer. For external opening, resolve handlers in this order: explicit Open With selection, matching user rule, operating-system default. Advanced rules may match extensions or content types and optionally a host or path pattern. More specific rules win; present the precedence clearly and allow reset to the system default.

Default user choices affect Farshore only. Changing global operating-system associations requires a separate explicit action; it must not happen silently when choosing Remember in Farshore.

### Application entries

Each entry stores a stable application identifier where available, display name, executable or application location, supported input mode, and optional arguments. Re-resolve moved applications by identifier. Missing applications offer a replacement chooser instead of silently launching another program.

Support these input modes:

| Mode | Behavior |
| --- | --- |
| Mounted file | Default for ordinary desktop apps; pass a local-looking path backed by SSH |
| Stream URL | Optional for compatible apps; use a protected local endpoint with seeking support |
| Explicit local copy | User-selected compatibility fallback for apps that require a complete local file |

Custom arguments are structured argument arrays with documented placeholders such as a file path or URL. Never interpolate filenames into shell command strings. Preserve filenames with spaces, quotes, dollar signs, and other special characters literally.

For macOS, use native application discovery and launching APIs through a small platform integration layer. Operating-system support for opening URLs in a chosen app is documented in [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:)).

### External app lifecycle

Keep an active mount available independently of the browsing tab. Closing a tab must not interrupt an externally opened file. Before disconnecting or quitting while handles or writes remain active, show the affected host and offer a safe choice. A timeout alone is not proof an external application has finished reading.

## 8 Filesystem and streaming contract

SMB feels transparent because the operating system implements a filesystem client. SFTP supplies remote file operations, including offset reads, but arbitrary desktop applications do not automatically understand an SFTP location. Farshore needs a local bridge that translates ordinary filesystem operations into SSH-backed operations.

The user-facing result should be a path such as a mounted host directory. The exact mount root is an implementation decision; do not expose an unstable internal path as a permanent bookmark format.

### Required behavior

- Read from arbitrary offsets and return correct byte counts and end-of-file behavior.
- Support concurrent opens, seeking, metadata reads, cancellation, and useful error reporting.
- Bound read-ahead and cache storage; external playback has priority over background thumbnails.
- Detect stale or replaced remote files so resumed reads do not silently combine different versions.
- Preserve logical host identity across mounts and sessions.
- Avoid whole-file materialization as the default Open operation.
- Make explicit when an app or format causes substantial reads; buffering is expected, invisible permanent downloads are not.

Arbitrary applications cannot be guaranteed never to read an entire file. The contract is that Farshore supports incremental access and does not itself require a complete download before opening a compatible file.

### Write behavior

The first technical gate is read-only. Before enabling external editing, test temporary-file saves, atomic rename, replacement, truncation, permissions, locking assumptions, disconnects, and conflicts with remote changes. An application receiving a successful save result must not later discover that its data was discarded during cache eviction.

Unsupported write patterns should fail clearly. Do not present a writable mount that only works for a subset of simple overwrite operations without explaining the limit.

## 9 Cache and transfer policy

Keep separate budgets and lifecycle rules for directory metadata, thumbnails, read buffers, explicit offline copies, and pending writes. The user must be able to inspect disk usage and clear safe caches without deleting remote files.

Proposed defaults for validation are a 512 MiB thumbnail budget and a 2 GiB media-read cache, with bounded per-file memory buffers. These are tuning hypotheses, not final performance guarantees. Choose final defaults after measurement on the real machines.

Read caches should be sparse where supported and evicted by usefulness and recency. Protect in-flight reads from eviction. A cache key must include file identity metadata; invalidate on detected changes. Pending writes must never share an ordinary disposable cache lifecycle.

Downloads use a destination chosen by the user or an explicit download preference. Transfer progress shows the host, destination, amount transferred, completion status, and cancel action. Partial downloads must be labeled and resumable only after confirming the source is compatible.

Avoid claiming an estimated time remaining before there is enough transfer history to support one. A useful activity view should distinguish playback buffering from an explicit saved download.

## 10 File operations

After the read path is stable, implement create folder, rename, upload, download, and copy with clear source and destination semantics. Cross-host moves must be treated as copy plus a separately verified deletion, not as an atomic rename.

Deletion requires an honest recovery model. If the backend has no reliable remote trash, do not label the action Move to Trash. Prefer a verified reversible strategy or clearly explain permanent deletion and obtain the appropriate confirmation. Do not invent undo for an irreversible operation.

For external editing, detect remote modifications before replacing an older cached copy. Show a conflict with options to preserve both versions. Do not choose last-write-wins silently.

File-management controls may be omitted or disabled in the first prototype. A release is not permitted to expose nonfunctional actions just to complete the layout.

## 11 Proposed technical architecture

### Framework

Flutter is recommended because it provides desktop targets for macOS, Windows, and Linux and supports custom platform integration. See [Flutter desktop support](https://docs.flutter.dev/platform-integration/desktop). React Native remains an alternative; macOS uses Microsoft's [React Native macOS implementation](https://github.com/microsoft/react-native-macos).

Choose based on desktop input quality, accessibility, native menus, virtualized media performance, maintainability, and native integration effort. Both need platform-specific code for application discovery and filesystem behavior. Do not select purely on how quickly a static screen can be produced.

### Components

| Component | Responsibility |
| --- | --- |
| Desktop UI | Navigation, views, inspector, settings, accessible input, activity |
| Connection service | Effective SSH configuration, host identity, sessions, recovery |
| Remote filesystem interface | List, stat, range read, path resolution, later mutations |
| Mount service | Present normal paths to external apps and manage mount lifetime |
| Preview workers | Decode media and generate thumbnails with budgets and cancellation |
| Handler service | Discover apps, resolve rules, launch selected apps safely |
| Local state | Preferences, favorites, associations, cache metadata, diagnostics |

The browser and filesystem mount should share connection and caching policy where feasible. A helper subprocess must use versioned, bounded messages, explicit lifecycle management, and sanitized logs. The UI must not scrape uncontrolled human-readable process output as a permanent API if structured output is available.

### Engine evaluation

Evaluate rclone as the first open-source engine candidate. Its SFTP backend can invoke an external SSH binary, allowing configuration to remain with OpenSSH. Its local NFS mount facilities are experimental and must pass the technical gate before selection. See [rclone SFTP external SSH support](https://rclone.org/sftp/#ssh) and [rclone nfsmount](https://rclone.org/commands/rclone_nfsmount/).

A local bridge on the Mac may use NFS internally while all traffic to the remote machine remains SSH. This is compatible with the no-server-setup requirement only if no remote NFS service, package, port, or configuration is introduced. Any local listener must bind to loopback and have a documented local-access threat model.

If that route fails correctness or performance requirements, evaluate another maintained open-source mount engine or a native macOS filesystem implementation. Do not assume Apple's File Provider APIs provide the desired incremental-read behavior. Prove their materialization semantics before considering them. Do not silently introduce a proprietary driver or a kernel-extension requirement to claim the app is fully open source.

Keep engine selection behind interfaces. Do not build a new SSH implementation or custom cryptography. If a full custom filesystem becomes necessary, revise the engineering estimate and scope before committing to it.

### Local stream endpoint

A local HTTP range endpoint is an optional adapter for URL-capable apps, not the universal file-opening solution. If implemented, bind to loopback, use scoped unguessable tokens, validate paths, restrict methods, avoid directory exposure, and invalidate access at the appropriate lifecycle boundary. Do not put SSH credentials into URLs.

## 12 State and identity model

Use explicit models for Host, Connection, Location, RemoteEntry, MountSession, PreviewJob, HandlerRule, TransferJob, and CacheEntry.

A Host has an internal ID, display alias, source configuration, and effective connection identity. A Location combines host ID and remote path; it must not be stored only as a local mount path. A RemoteEntry includes type, size, modification time, permissions where available, symlink state, and a freshness marker.

Handler rules include matching scope, selected app identifier, input mode, arguments, and precedence. Transfer jobs record source identity and destination explicitly. Cache entries record origin, validation metadata, storage cost, and whether eviction is safe.

Persist preferences using a versioned schema with migration tests. Keep secrets in platform storage and diagnostic records separate from user preferences. Exports should omit credentials by default.

## 13 Performance and usability targets

These are proposed acceptance targets to measure and tune on a documented LAN baseline. They are not claims about the current machines or every network.

| Scenario | Initial target |
| --- | --- |
| Open a warm directory containing 1,000 entries | Useful filenames visible within 1 second |
| Open a cold directory on an existing healthy connection | Useful initial listing within 2 seconds |
| Grid scrolling | Target 60 fps on the development Mac, without decoder work on the UI thread |
| First visible thumbnails | Begin appearing within 2 seconds for a representative cached or small-image set |
| Open a seekable multi-gigabyte video | Start within 5 seconds on the baseline LAN without fetching the full file first |
| Seek forward or backward | Resume within 3 seconds on the same baseline, subject to format and bitrate |
| Background work | Bounded concurrency and responsive navigation under thumbnail load |
| Cache | Stay within configured budgets after eviction settles |

Record cold and warm runs separately. Measure bytes read before playback and after seeking, not merely the time until an external app opens. Test files larger than the configured cache budget so accidental whole-file downloads are visible.

Avoid mandatory analytics services. Development measurements should be local, inspectable, and redact filenames when exported unless the user opts in.

## 14 Security and operating constraints

Remote access uses existing SSH permissions. No remote daemon installation, package setup, firewall changes, new account, or shared-folder configuration is part of the baseline product.

Local helpers must not listen on all interfaces. Never log secrets or forward them through media URLs. Validate all paths and protocol messages, keep app launching free of shell interpolation, and pin or verify distributed helper versions.

The app must not start mounting hosts, launching players, or scanning entire remote filesystems merely because it imported a configuration. Connecting to a host and viewing a folder should have predictable, bounded effects.

Package and signing decisions must account for helper executables, sandbox constraints, platform entitlements, updates, and dependency licenses. Keep an inventory of bundled dependencies and license notices. Public release, telemetry, update hosting, and commercial terms require their own product decisions.

## 15 Failure states

| Failure | Required behavior |
| --- | --- |
| Host offline | Preserve location and cached view; offer reconnect with clear state |
| Authentication unavailable | Identify the failed method without exposing secrets; allow retry or credential selection |
| Host identity changed | Stop connection and display the mismatch; preserve trusted keys |
| Permission denied | Identify the item or folder; keep unaffected navigation usable |
| Thumbnail unsupported | Show file icon and explanation; Open With remains available |
| External app missing | Offer another application or update the handler |
| Mount unavailable | Explain why Open cannot provide a path; offer an explicit download where appropriate |
| Local cache full | Evict safe cache entries or ask for space; preserve pending writes |
| Source changes during reading | Invalidate stale state and avoid silently merging different file versions |
| Disconnect during write | Preserve recoverable data and surface pending state; do not claim save completion falsely |
| Disconnect requested during playback | Explain active access and let the user decide how to proceed |

## 16 Acceptance scenarios

### SSH compatibility

Connect to the real Linux and server aliases using existing authentication and strict verification. When the Windows machine is available, validate its SFTP path handling and host identity independently. A shared IP must never cause the app to merge the Windows and Linux host records.

Verify that required SSH includes, key choices, host-key aliases, and any configured jump behavior work through the chosen engine. Unsupported configuration must produce a specific limitation rather than an insecure fallback.

### Playback and external applications

Open a representative multi-gigabyte MP4 and another seekable container in two available user-selected players. Seek near the beginning, middle, and end. Capture startup latency, read ranges, transferred bytes, cache growth, and error behavior. Confirm that no full copy is created in Downloads.

Set a player through application discovery, change the association, reopen the file, and observe the newly selected app. Restart Farshore and verify the rule persists. Also open an image and a text file through different handlers. The test must exercise real native launching rather than a hard-coded process name.

### Visual browsing

Browse a folder with mixed images, videos, unsupported files, and subfolders in grid, list, and gallery views. Confirm progressive thumbnails, correct aspect ratios, stable selection during loading, keyboard navigation, and a working inspector. Navigate rapidly between folders and verify stale work is canceled or deprioritized.

### Filesystem and recovery

Exercise concurrent external reads, Unicode and special-character paths, symlinks, remote replacement, cache pressure, disconnect/reconnect, app quit, and reopening a host. Ensure tab closure does not break an active external read. Read-only prototype mounts must refuse writes clearly.

### Write readiness

Before enabling writable external opening, verify atomic saves and conflicts using representative editors. Test a disconnect during save and recovery after restart. Rename and delete controls need backend verification and accurate recovery semantics.

## 17 Implementation milestones

### M0 Validate the technical foundation

Inventory the local toolchain, read effective SSH configuration without exporting secrets, and evaluate the candidate mount engine. Create only local helpers and scratch files. Use existing representative remote files for read tests. Record engine versions, launch commands, mount behavior, read metrics, app behavior, and limitations in `docs/technical-validation.md`.

Exit gate: strict SSH compatibility, working mounted paths, partial video reads and seeking, multiple configurable application launches, bounded cache behavior, and a viable thumbnail path. If any fail, resolve the architecture before presenting a polished shell as a working product.

### M1 Design system and working browser

Create the application scaffold and design tokens, then implement host navigation, tabs, breadcrumbs, directory listing, selection, grid/list/gallery views, and progressive real thumbnails. Review the interface at typical and narrow window sizes in both themes.

Exit gate: the real hosts and files are usable through the intended visual workflow, with keyboard and accessibility support established.

### M2 External opening and lifecycle

Implement discovery, system-default resolution, user rules, custom handlers, mounted opening, activity visibility, and mount lifetime management. Test normal and interrupted playback while navigating elsewhere.

Exit gate: the end-to-end opening scenarios pass without hard-coded players or hidden mandatory complete downloads.

### M3 Reliability and file operations

Implement connection recovery, cache management, diagnostics, explicit transfers, and safe basic file operations. Enable external editing only after write-readiness checks pass.

Exit gate: correct behavior under network interruption, stale files, low disk space, and representative edits; no data-loss issue remains open.

### M4 Package and refine

Finish visual polish, empty/error/loading states, accessibility, settings, packaging, signing, helper distribution, dependency notices, and user documentation. Review the complete experience with the user on the real workflow.

Exit gate: a packaged app that reproduces validated behavior outside the development environment.

## 18 Engineering estimate

Planning estimates for one experienced engineer using existing libraries are approximately 2–3 weeks for a focused prototype and 6–10 or more weeks for a dependable, polished first release. These are effort estimates, not a delivery commitment or a promise about an agent's wall-clock execution time.

The estimate assumes macOS first and reuse of a viable filesystem engine. Writing and maintaining a custom filesystem, adding full clients on other operating systems, broad external editing compatibility, or supporting every SSH edge case would increase scope materially. Re-estimate after M0 rather than hiding those costs inside UI work.

## 19 Decisions to record

| Decision | Current position | Resolution point |
| --- | --- | --- |
| Project name | Farshore is the working name chosen for the folder | Before public branding or distribution |
| UI framework | Flutter recommended; React Native remains an allowed option | Before scaffold commitment |
| Initial client platform | macOS proposed | At implementation kickoff |
| Filesystem engine | Existing open-source engine preferred; rclone is first candidate | M0 |
| Write support | Read-only technical gate, then explicit operations; external editing separately validated | M3 |
| Open-source license | MIT, selected by the user for public Awaisryk/farshore publication | Decided October 22, 2026 |
| Public distribution | Undecided; local development first | M4 planning |
| Internal video player | Common-format preview desirable; selected external apps remain essential | After M0 format tests |
| Automatic reconnect and launch | Conservative defaults; no surprise background activity | M2–M3 |

Treat framework and platform recommendations as sensible starting points, not blockers requiring a long questionnaire. Make routine implementation choices, record reasons, and ask only when a material product tradeoff cannot be resolved from this brief.

## 20 Fresh session handoff

No implementation has been started in this folder. The PRD and README are the deliverables from the planning session. No SMB setup should be resumed from the earlier conversation.

Begin by reading repository and parent instructions, inspecting the available Flutter/React Native and macOS toolchains, and choosing a small technical validation plan. Preserve existing SSH trust and credentials. Do not install anything on the remote machines or reorganize their files as part of this work.

Recommended files to create as work begins are `docs/technical-validation.md`, `docs/decisions.md`, a project-appropriate source tree, and a short implementation status document. Keep measured results separate from design targets. Keep secrets and generated caches out of version control.

The first demonstrable result should open a real remote video through a mounted path in an application selected at runtime, support seeking, and report its read/cache behavior. The next should browse real images with responsive thumbnails. Those two demonstrations establish that the product solves the original problem.

## 21 Reference documentation

- [Flutter desktop support](https://docs.flutter.dev/platform-integration/desktop): supported desktop targets and plugin model.
- [Flutter platform integration](https://docs.flutter.dev/platform-integration): native integration guidance.
- [React Native macOS](https://github.com/microsoft/react-native-macos): desktop implementation and project requirements.
- [Apple NSWorkspace application opening](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:)): launch files or URLs in a selected application.
- [rclone SFTP](https://rclone.org/sftp/): SSH backend configuration, external SSH operation, and host verification options.
- [rclone nfsmount](https://rclone.org/commands/rclone_nfsmount/): experimental mount candidate requiring validation.
- [rclone local NFS serving](https://rclone.org/commands/rclone_serve_nfs/): local bridge behavior and binding considerations.

These references support implementation choices, not guarantees that an untested combination meets Farshore's acceptance criteria. Recheck current versions and licenses when selecting dependencies.
