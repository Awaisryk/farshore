#!/bin/sh
set -eu

source_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
go_binary=${GO_BINARY:-go}
case "$("$go_binary" version)" in
  'go version go1.26.9 darwin/arm64') ;;
  *) echo 'Use the official Go1.26.9 darwin/arm64 toolchain described in README.md.' >&2; exit 1 ;;
esac
python3 "$source_root/verify-sources.py"
python3 - "$source_root" <<'PY'
from pathlib import Path
import sys,zipfile
root=Path(sys.argv[1])
target=root/'.work/rclone'
if not target.exists():
    target.mkdir(parents=True)
    with zipfile.ZipFile(root/'rclone-source.zip') as source:
        prefix=source.namelist()[0]
        for info in source.infolist():
            relative=info.filename.removeprefix(prefix)
            if not relative or info.is_dir():
                continue
            path=target/relative
            if not path.resolve().is_relative_to(target.resolve()):
                raise ValueError('Unexpected source path')
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(source.read(info))
PY
proxy_url=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().as_uri())' "$source_root/module-proxy")
export GOPROXY="$proxy_url"
export GOSUMDB=off
export GOTOOLCHAIN=local
export GOTELEMETRY=off
export GOMODCACHE="$source_root/.work/gomodcache"
export GOCACHE="$source_root/.work/gocache"
export GOOS=darwin
export GOARCH=arm64
export GOARM64=v8.0
export CGO_ENABLED=1
mkdir -p "$source_root/output"
cd "$source_root/.work/rclone"
set -- -mod=readonly -trimpath -buildvcs=false -p "${BUILD_PARALLELISM:-2}" -tags=cmount
if [ -n "${SDDL_SOURCE:-}" ]; then
  cp go.mod "$source_root/.work/relink.mod"
  cp go.sum "$source_root/.work/relink.sum"
  "$go_binary" mod edit "-modfile=$source_root/.work/relink.mod" "-replace=github.com/cloudsoda/sddl=$SDDL_SOURCE"
  set -- "$@" "-modfile=$source_root/.work/relink.mod"
fi
"$go_binary" build "$@" -ldflags '-s -X github.com/rclone/rclone/fs.Version=v1.75.2' -o "$source_root/output/rclone" .
"$source_root/output/rclone" version
