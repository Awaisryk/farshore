# rclone 1.75.2 corresponding source and relinking

This archive accompanies the unchanged official rclone v1.75.2 macOS arm64 CLI
used by Farshore 0.2.0 beta. Farshore invokes rclone as a separate process.
The Farshore application source is licensed separately under MIT. This archive
does not change the licenses of upstream components or restrict their use.

The rclone executable contains `github.com/cloudsoda/sddl` at
`v0.0.0-20250224235906-926454e91efc`, licensed under LGPL version 3. Its use in
rclone is covered by that license. The original LGPL and GPL version 3 texts
are supplied as `LGPL-3.0.txt` and `GPL-3.0.txt`. The complete, unmodified library
source is in the corresponding `module-proxy` ZIP. The other rclone source and
dependency source supplied here permit rebuilding rclone with a modified copy
of this library. Reverse engineering to debug modifications to the LGPL
component is permitted; no Farshore term restricts those rights.

The archive also contains the exact source of the eight MPL-2.0 dependencies.
Their covered files remain under MPL-2.0; original license and notice documents
are retained in `notices/` and within their module source ZIPs. No changes were
made to the upstream rclone or dependency source used in the distributed binary.

## Contents and provenance

- `rclone-source.zip`: complete upstream source at commit
  `be8d6044eacb843b74d335db0c5fbe09222031fe` (tag v1.75.2), including build scripts,
  `go.mod`, `go.sum`, MIT license, C/Go source and embedded resources.
- `module-proxy/`: exact source ZIPs for all 242 compiled dependency modules,
  plus version and module-graph metadata. Every compiled ZIP was checked against
  the Go `h1:` checksum embedded in the official binary. The full application
  and library source are supplied, so relinking does not require closed object
  files or a developer signing key.
- `go1.26.9-source.tar.gz`: official source for the general-purpose Go toolchain.
- `macfuse-headers-source.tar.gz`: complete official macFUSE user-space library
  source at commit `7a6cdd2b6e11071a706f4295aa931c65223ba953`, including the
  FUSE2 interface headers and original GPL/LGPL license texts. Only the headers
  are used for this verified `cmount` relink. No driver, library or system package
  is installed. This is a compatible pinned SDK; the upstream executable does
  not record the exact FUSE SDK revision used in its original build.
- `source-manifest.json`: file checksums, upstream URLs, exact versions and
  official toolchain provenance. `verify-sources.py` verifies the original inputs.
- `build-rclone.sh`: offline build using the included module proxy. It writes
  only `.work/` and `output/` inside this extracted archive.

## Rebuild on Apple Silicon macOS

Install Apple's Command Line Tools (a full Xcode installation is unnecessary).
Use the official **Go1.26.9 darwin/arm64** toolchain:

<https://go.dev/dl/go1.26.9.darwin-arm64.tar.gz>

SHA-256: `f9bb7c0a02506c5d9bf0d1eb1f7ee6c7684f844ae49558308a0427b830e022cc`

Extract that toolchain, then run this archive's script, setting its absolute path:

```sh
GO_BINARY="/absolute/path/to/go/bin/go" sh ./build-rclone.sh
```

The build uses `GOOS=darwin`, `GOARCH=arm64`, `GOARM64=v8.0`, `CGO_ENABLED=1`,
the `cmount` build tag, `-trimpath`, and linker flags
`-s -X github.com/rclone/rclone/fs.Version=v1.75.2`. These are the relevant
upstream release settings recorded in the official binary. `-buildvcs=false`
avoids adding metadata from an unrelated enclosing Git checkout. Signing and
build metadata can differ; this is a functional relink procedure, not a claim
that the rebuilt executable will have an identical byte hash.

The script supplies the bundled FUSE2 headers through `CGO_CFLAGS`. A filesystem
driver is unnecessary to compile the helper or use Farshore's SFTP/NFS paths.

The Go toolchain and Python3 are general-purpose build tools. No internet access
is needed during the supplied rclone build once those tools are installed.
The script disables enclosing Go workspaces and global Go environment/flag
overrides, and forces the local proxy even if private-module settings are inherited.

## Modify and relink the LGPL library

Extract the exact library source to a writable directory:

```sh
unzip module-proxy/github.com/cloudsoda/sddl/@v/v0.0.0-20250224235906-926454e91efc.zip -d editable
```

Edit the source under
`editable/github.com/cloudsoda/sddl@v0.0.0-20250224235906-926454e91efc/`, then run:

```sh
SDDL_SOURCE="/absolute/path/to/editable/github.com/cloudsoda/sddl@v0.0.0-20250224235906-926454e91efc" \
GO_BINARY="/absolute/path/to/go/bin/go" sh ./build-rclone.sh
```

`SDDL_SOURCE` adds a local Go module replacement in a separate modfile. The
original input archives remain untouched. You may also edit the extracted
application in `.work/rclone/` or apply normal Go module replacements to relink
other supplied dependencies. Their original license terms continue to apply.

## Use the relinked executable with Farshore

Quit Farshore and preserve a backup of the application. Replace its CLI helper
with the rebuilt executable, then ad-hoc sign your local application copy:

```sh
cp output/rclone /Applications/Farshore.app/Contents/Resources/Runtime/bin/rclone
chmod +x /Applications/Farshore.app/Contents/Resources/Runtime/bin/rclone
codesign --force --sign - /Applications/Farshore.app/Contents/Resources/Runtime/bin/rclone
codesign --force --deep --sign - /Applications/Farshore.app
```

Adjust the application path if needed; a writable copy in your own Applications
folder also works. Ad-hoc signing uses no Apple account or private signing key.
macOS may ask you to open the modified local application again through Finder's
Open action. Farshore does not enforce a cryptographic lock on the rclone helper.

## Source availability

The matching source archive is distributed with the binary release at:

<https://github.com/Awaisryk/farshore/releases/download/v0.2.0-beta.1/Farshore-0.2.0-rclone-corresponding-source.zip>

Per-module upstream URLs and checksums are in `source-manifest.json`. Library
license texts and notices are also available inside Farshore at
`Contents/Resources/Runtime/licenses/rclone-third-party/` and in its consolidated
third-party notices. Source is provided under each component's original terms.
