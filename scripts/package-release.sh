#!/bin/bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="${1:-$project_root/build/Farshore.app}"
output="${2:-$project_root/dist}"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$source_app/Contents/Info.plist")
build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$source_app/Contents/Info.plist")
mkdir -p "$output"
source_asset="${FARSHORE_SOURCE_ASSET:-$output/Farshore-$version-rclone-corresponding-source.zip}"
staging=$(mktemp -d "$output/.package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Farshore.app"
/usr/bin/ditto "$source_app" "$app"
/usr/bin/python3 - "$project_root" "$app" "$source_asset" <<'PY'
import hashlib,json,pathlib,shutil,sys
root,app,source_asset=map(pathlib.Path,sys.argv[1:])
source=root/'licenses/rclone-third-party'
inventory=source/'inventory.json'
if not inventory.is_file() or json.loads(inventory.read_text()).get('complete') is not True:
    raise SystemExit('Complete, verified rclone dependency notices are required before packaging a public ZIP.')
provision=json.loads(inventory.read_text()).get('sourceProvision',{})
if not source_asset.is_file() or provision.get('asset')!=source_asset.name:
    raise SystemExit('The matching rclone corresponding-source ZIP must be available beside the release.')
digest=hashlib.sha256()
with source_asset.open('rb') as stream:
    for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
if digest.hexdigest()!=provision.get('sha256'):
    raise SystemExit('Corresponding-source ZIP does not match the vetted license inventory.')
target=app/'Contents/Resources/Runtime/licenses/rclone-third-party'
if target.exists():shutil.rmtree(target)
shutil.copytree(source,target)
for source_name,target_name in [('LICENSE','Farshore-MIT.txt'),('docs/dependencies.md','DEPENDENCIES.md')]:
    shutil.copy2(root/source_name,app/'Contents/Resources/Runtime/licenses'/target_name)
PY
/usr/bin/python3 "$project_root/scripts/write-notices.py" "$app"
/usr/bin/python3 "$project_root/scripts/sign-app.py" "$app"
artifact="$output/Farshore-$version-macos-arm64-beta.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$artifact"
notarized=false
if [[ -n "${FARSHORE_NOTARY_PROFILE:-}" ]]; then
    if [[ "${FARSHORE_SIGN_IDENTITY:-}" != 'Developer ID Application:'* ]]; then
        echo 'Notarization requires FARSHORE_SIGN_IDENTITY set to Developer ID Application.' >&2
        exit 1
    fi
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    xcrun notarytool submit "$artifact" --keychain-profile "$FARSHORE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute "$app"
    /bin/rm "$artifact"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$artifact"
    notarized=true
fi
/usr/bin/python3 - "$artifact" "$version" "$build" "$notarized" "$project_root" "$source_asset" <<'PY'
import hashlib,json,os,pathlib,sys
def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
    return digest.hexdigest()
artifact=pathlib.Path(sys.argv[1]); digest=sha(artifact)
source=pathlib.Path(sys.argv[6]);inventory=json.loads((pathlib.Path(sys.argv[5])/'licenses/rclone-third-party/inventory.json').read_text())
manifest={'version':sys.argv[2],'build':sys.argv[3],'architecture':'arm64','deploymentTargetMacOS':'12.0','testedMacOS':'26.4',
          'channel':'beta','artifact':artifact.name,'sha256':digest,'notarized':sys.argv[4]=='true',
          'signing':'developer-id' if os.environ.get('FARSHORE_SIGN_IDENTITY','-')!='-' else 'ad-hoc',
          'runtime':json.loads((pathlib.Path(sys.argv[5])/'scripts/runtime-lock.json').read_text()),
          'correspondingSource':{**inventory['sourceProvision'],'size':source.stat().st_size}}
manifest_path=artifact.parent/'release-manifest.json'
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
(artifact.parent/'SHA256SUMS').write_text(''.join(sha(path)+'  '+path.name+'\n' for path in [artifact,source,manifest_path]))
print(json.dumps({'artifact':str(artifact),'sha256':digest,'notarized':manifest['notarized'],'signing':manifest['signing']}))
PY
