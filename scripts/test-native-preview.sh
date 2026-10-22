#!/bin/bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
frameworks="$project_root/build/Farshore.app/Contents/Frameworks"
if [[ ! -d "$frameworks/FlutterMacOS.framework" ]]; then
    echo "Build Farshore once before running the isolated native preview smoke." >&2
    exit 1
fi
mkdir -p "$project_root/.build"
smoke_root="$(mktemp -d "$project_root/.build/preview-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
smoke_app="$smoke_root/PreviewSmoke.app"
mkdir -p "$smoke_app/Contents/MacOS" "$smoke_root/state/previews"
cat "$project_root/native/FarshorePreview.swift" "$project_root/tests/native/preview_smoke.swift" > "$smoke_root/PreviewSmoke.swift"
cat > "$smoke_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.farshore.preview-smoke</string><key>CFBundleExecutable</key><string>PreviewSmoke</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
xcrun swiftc -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macos12.0" -module-cache-path "$project_root/.build/swift-preview-module-cache" \
    -F "$frameworks" -framework AppKit -framework FlutterMacOS -framework QuickLookUI \
    -Xlinker -rpath -Xlinker "$frameworks" "$smoke_root/PreviewSmoke.swift" \
    -o "$smoke_app/Contents/MacOS/PreviewSmoke"
/usr/bin/codesign --force --sign - "$smoke_app" >/dev/null
python3 - "$smoke_root" <<'PY'
import os, pathlib, subprocess, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root / 'state/previews/fixture.docx', 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
    archive.writestr('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
    archive.writestr('word/document.xml', '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Farshore isolated Office preview fixture.</w:t></w:r></w:p></w:body></w:document>')
environment = dict(os.environ, FARSHORE_STATE=str(root / 'state'))
result = subprocess.run([str(root / 'PreviewSmoke.app/Contents/MacOS/PreviewSmoke')], env=environment,
                        capture_output=True, text=True, timeout=20)
print(result.stdout, end='')
if result.returncode:
    print(result.stderr, file=sys.stderr, end='')
sys.exit(result.returncode)
PY
