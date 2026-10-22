#!/bin/bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_root/.build"
staging=$(mktemp -d "$project_root/.build/vlc-identity.XXXXXX")
trap 'rm -rf "$staging"' EXIT
cat "$project_root/native/FarshoreVideo.swift" > "$staging/IdentitySmoke.swift"
cat >> "$staging/IdentitySmoke.swift" <<'SWIFT'

@main
struct VideoLANIdentitySmoke {
    static func main() throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") else {
            print("VLC_IDENTITY_SMOKE=skipped-no-installed-vlc")
            return
        }
        let library = try FarshoreLibVLC(applicationURL: url)
        guard library.version.hasPrefix("3.") else { fatalError("Unexpected library version.") }
        let invalid = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        do {
            _ = try validatedVideoLANApplication(invalid)
            fatalError("Unsigned application was admitted.")
        } catch is FarshoreVideoFailure {}
        print("VLC_IDENTITY_SMOKE=passed SIGNED_INSTALL_ACCEPTED=true UNSIGNED_REJECTED=true VERSION=\(library.version)")
    }
}
SWIFT
frameworks="$project_root/build/Farshore.app/Contents/Frameworks"
xcrun swiftc -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macos12.0" -module-cache-path "$project_root/.build/swift-preview-module-cache" \
    -F "$frameworks" -framework AppKit -framework FlutterMacOS -framework Security \
    -Xlinker -rpath -Xlinker "$frameworks" "$staging/IdentitySmoke.swift" -o "$staging/IdentitySmoke"
"$staging/IdentitySmoke" "$staging/Unsigned.app"
