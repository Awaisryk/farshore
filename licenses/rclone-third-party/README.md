# rclone third-party notices and provenance

These documents correspond to the official rclone v1.75.2 macOS arm64 archive.
`inventory.json` records the archive and executable SHA-256 digests, exact Go
build information, all 242 compiled module versions and their embedded Go
checksums. Original license, copyright, patent, author and notice files retain
their upstream names and bytes. Module-level collection intentionally includes
some documents belonging to source packages not linked on macOS.

Go module source ZIPs were obtained from the official Go module proxy and
verified with the Go `h1:` directory-hash algorithm against the binary's build
information. The Go1.26.9 source archive was verified against the checksum
published by go.dev. SPDX's pinned v3.27.0 license-data release supplies the
canonical GPL3 text accompanying the original LGPL3 library license.

Eight dependencies use MPL2.0 and `github.com/cloudsoda/sddl` uses LGPL3. Their
source availability, the matching complete rclone source/relink asset, original
terms and installation instructions are explained in `SOURCE_AVAILABILITY.txt`
and `RELINKING.md`. No upstream application or dependency source was modified in
the shipped rclone executable. `complete:true` is emitted only after the source
asset exists, its checksum matches, and both the baseline build and a build using
a modified LGPL library were actually validated.

To reproduce the collection and release asset on Apple Silicon macOS with
Command Line Tools installed:

```sh
python3 scripts/collect-rclone-notices.py --collect --prepare --validate --package
```

The command uses eight bounded download workers and two compiler workers. It
stores downloads under `.tools`, validation work under `.build`, the public
notices here, and the final corresponding-source ZIP under `dist`. The compiler
uses the supplied offline module proxy. Original inputs and source-asset
checksums are recorded; local caches, log files, paths, SSH configuration and
runtime application state are excluded from the asset.

Algorithm references: [Go build information](https://go.dev/src/debug/buildinfo/buildinfo.go),
[Go module directory hashes](https://go.googlesource.com/mod/+/refs/heads/master/sumdb/dirhash/hash.go).
Upstream releases: [rclone v1.75.2](https://github.com/rclone/rclone/releases/tag/v1.75.2),
[Go1.26.9](https://go.dev/dl/#go1.26.9),
[SPDX GPL3 text](https://github.com/spdx/license-list-data/blob/v3.27.0/text/GPL-3.0-only.txt).
