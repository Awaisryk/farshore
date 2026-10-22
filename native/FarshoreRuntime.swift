import Foundation
import Darwin

/// The packaged application runs entirely from its sealed Resources directory.
/// Explicit environment overrides remain useful for isolated tests/development.
enum FarshoreRuntime {
    static func legacyStates(state: URL) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        var paths = environment["FARSHORE_LEGACY_STATES"]?.split(separator: ":").map(String.init) ?? []
        let manifest = state.appendingPathComponent("legacy-states.json")
        if let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536,
           let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["version"] as? Int == 1, let roots = json["roots"] as? [String] {
            paths.append(contentsOf: roots.prefix(16))
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            guard path.hasPrefix("/"), !path.contains(":"), !path.contains("\0") else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
                  seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    static func configure(bundle: Bundle = .main) throws {
        let manager = FileManager.default
        let runtime = bundle.resourceURL?.appendingPathComponent("Runtime", isDirectory: true)
        guard let runtime, manager.fileExists(atPath: runtime.appendingPathComponent("backend/farshore_bridge.py").path) else {
            if bundle.object(forInfoDictionaryKey: "FarshorePortableRuntime") as? Bool == true {
                throw CocoaError(.fileNoSuchFile)
            }
            let root = ProcessInfo.processInfo.environment["FARSHORE_ROOT"]
                ?? bundle.object(forInfoDictionaryKey: "FarshoreDevelopmentRoot") as? String
            if let root, manager.fileExists(atPath: (root as NSString).appendingPathComponent("pubspec.yaml")) {
                setenv("FARSHORE_ROOT", root, 1)
                manager.changeCurrentDirectoryPath(root)
            }
            return
        }
        func defaultValue(_ name: String, _ value: String) {
            if ProcessInfo.processInfo.environment[name] == nil { setenv(name, value, 1) }
        }
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Farshore", isDirectory: true)
        let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Farshore", isDirectory: true)
        defaultValue("FARSHORE_ROOT", runtime.path)
        defaultValue("FARSHORE_PYTHON", runtime.appendingPathComponent("python/bin/python3").path)
        defaultValue("FARSHORE_BRIDGE_SCRIPT", runtime.appendingPathComponent("backend/farshore_bridge.py").path)
        defaultValue("FARSHORE_NATIVE", runtime.appendingPathComponent("bin/farshore-native").path)
        defaultValue("FARSHORE_RCLONE", runtime.appendingPathComponent("bin/rclone").path)
        defaultValue("RCLONE", ProcessInfo.processInfo.environment["FARSHORE_RCLONE"]!)
        defaultValue("FARSHORE_STATE", support.path)
        defaultValue("FARSHORE_CACHE", cache.path)
        defaultValue("FARSHORE_NOTICES", bundle.resourceURL!.appendingPathComponent("THIRD_PARTY_NOTICES.txt").path)
        defaultValue("PYTHONDONTWRITEBYTECODE", "1")
        defaultValue("PYTHONNOUSERSITE", "1")
        for key in ["FARSHORE_STATE", "FARSHORE_CACHE"] {
            let path = ProcessInfo.processInfo.environment[key]!
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try manager.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FARSHORE_STATE"]!, isDirectory: true)
        let legacy = legacyStates(state: state)
        if !legacy.isEmpty { setenv("FARSHORE_LEGACY_STATES", legacy.map(\.path).joined(separator: ":"), 1) }
        manager.changeCurrentDirectoryPath(ProcessInfo.processInfo.environment["FARSHORE_ROOT"]!)
    }
}
