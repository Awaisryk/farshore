import AppKit
import Darwin
import FlutterMacOS
import Foundation
import Security

private func validatedVideoLANApplication(_ candidate: URL) throws -> URL {
    let application = candidate.standardizedFileURL.resolvingSymlinksInPath()
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let rule = "anchor apple generic and identifier \"org.videolan.vlc\" and certificate leaf[subject.OU] = \"75GAHG3SZQ\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
    guard application.pathExtension.lowercased() == "app",
          SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess,
          SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
          let code, let requirement,
          SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
        throw FarshoreVideoFailure(code: "libvlc-untrusted", message: "Embedded playback requires an intact VLC application signed by VideoLAN. Install the official VLC application, or use Open With.")
    }
    return application
}

// Runtime-only LibVLC 3 adapter. The installed VideoLAN application provides
// its library and plugins; Farshore does not copy or modify that installation.
// Signatures match the public VLC 3 headers shipped with the discovered app.
private struct FarshoreVideoFailure: Error {
    let code: String
    let message: String
}

private final class FarshoreLibVLC {
    typealias GetVersion = @convention(c) () -> UnsafePointer<CChar>?
    typealias New = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> OpaquePointer?
    typealias Release = @convention(c) (OpaquePointer?) -> Void
    typealias NewPath = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> OpaquePointer?
    typealias MediaOption = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias SetMedia = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    typealias SetDrawable = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    typealias IntegerQuery = @convention(c) (OpaquePointer?) -> Int32
    typealias IntegerCommand = @convention(c) (OpaquePointer?, Int32) -> Void
    typealias Volume = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias Position = @convention(c) (OpaquePointer?) -> Float
    typealias SetPosition = @convention(c) (OpaquePointer?, Float) -> Void
    typealias Time = @convention(c) (OpaquePointer?) -> Int64
    typealias VideoSize = @convention(c) (OpaquePointer?, UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32

    let version: String
    let createInstance: New
    let releaseInstance: Release
    let createMedia: NewPath
    let createLocation: NewPath
    let releaseMedia: Release
    let addMediaOption: MediaOption
    let createPlayer: @convention(c) (OpaquePointer?) -> OpaquePointer?
    let releasePlayer: Release
    let setMedia: SetMedia
    let setDrawable: SetDrawable
    let play: IntegerQuery
    let pause: IntegerCommand
    let stop: Release
    let setPosition: SetPosition
    let setVolume: Volume
    let position: Position
    let length: Time
    let time: Time
    let state: IntegerQuery
    let isPlaying: IntegerQuery
    let isSeekable: IntegerQuery
    let videoSize: VideoSize

    init(applicationURL: URL) throws {
        let applicationURL = try validatedVideoLANApplication(applicationURL)
        let macOS = applicationURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let core = macOS.appendingPathComponent("lib/libvlccore.dylib")
        let library = macOS.appendingPathComponent("lib/libvlc.dylib")
        let plugins = macOS.appendingPathComponent("plugins", isDirectory: true)
        var directory: ObjCBool = false
        guard [core, library, plugins].allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(macOS.path + "/") }),
              FileManager.default.isReadableFile(atPath: library.path),
              FileManager.default.fileExists(atPath: plugins.path, isDirectory: &directory), directory.boolValue,
              // VLC's binary references its core as @rpath/libvlccore.dylib.
              // Load that dependency by discovered absolute path first; no
              // VLC-specific link-time rpath or DYLD environment is needed.
              dlopen(core.path, RTLD_NOW | RTLD_LOCAL) != nil,
              let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            throw FarshoreVideoFailure(code: "libvlc-unavailable", message: "The installed VideoLAN library could not be loaded. Use Open With or reinstall VLC.")
        }
        // Do not dlclose after successful loading: Cocoa video-output modules
        // may still have asynchronous AppKit work during player teardown.
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw FarshoreVideoFailure(code: "libvlc-incompatible", message: "The installed VideoLAN library lacks a required playback API. Use Open With.")
            }
            return unsafeBitCast(pointer, to: type)
        }
        let getVersion = try symbol("libvlc_get_version", GetVersion.self)
        version = getVersion().map { String(cString: $0) } ?? "unknown"
        guard version.hasPrefix("3.") else {
            throw FarshoreVideoFailure(code: "libvlc-incompatible", message: "Embedded playback currently supports LibVLC 3. The installed library reports \(version). Use Open With.")
        }
        createInstance = try symbol("libvlc_new", New.self)
        releaseInstance = try symbol("libvlc_release", Release.self)
        createMedia = try symbol("libvlc_media_new_path", NewPath.self)
        createLocation = try symbol("libvlc_media_new_location", NewPath.self)
        releaseMedia = try symbol("libvlc_media_release", Release.self)
        addMediaOption = try symbol("libvlc_media_add_option", MediaOption.self)
        createPlayer = try symbol("libvlc_media_player_new", (@convention(c) (OpaquePointer?) -> OpaquePointer?).self)
        releasePlayer = try symbol("libvlc_media_player_release", Release.self)
        setMedia = try symbol("libvlc_media_player_set_media", SetMedia.self)
        setDrawable = try symbol("libvlc_media_player_set_nsobject", SetDrawable.self)
        play = try symbol("libvlc_media_player_play", IntegerQuery.self)
        pause = try symbol("libvlc_media_player_set_pause", IntegerCommand.self)
        stop = try symbol("libvlc_media_player_stop", Release.self)
        setPosition = try symbol("libvlc_media_player_set_position", SetPosition.self)
        setVolume = try symbol("libvlc_audio_set_volume", Volume.self)
        position = try symbol("libvlc_media_player_get_position", Position.self)
        length = try symbol("libvlc_media_player_get_length", Time.self)
        time = try symbol("libvlc_media_player_get_time", Time.self)
        state = try symbol("libvlc_media_player_get_state", IntegerQuery.self)
        isPlaying = try symbol("libvlc_media_player_is_playing", IntegerQuery.self)
        isSeekable = try symbol("libvlc_media_player_is_seekable", IntegerQuery.self)
        videoSize = try symbol("libvlc_video_get_size", VideoSize.self)
        // VLC expects this environment variable before libvlc_new. It contains
        // only the discovered local plugin directory, never remote credentials.
        setenv("VLC_PLUGIN_PATH", plugins.path, 1)
    }

    func newInstance() -> OpaquePointer? {
        let arguments = ["--quiet", "--ignore-config", "--no-video-title-show", "--no-media-library",
                         "--no-metadata-network-access", "--no-sub-autodetect-file",
                         "--vout=macosx", "--file-caching=500"]
        let storage = arguments.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = storage.map { $0.map { UnsafePointer($0) } }
        return pointers.withUnsafeBufferPointer { createInstance(Int32($0.count), $0.baseAddress) }
    }
}

private final class FarshoreLibVLCLoader {
    private let lock = NSLock()
    private let applicationURL: URL?
    private var cached: Result<FarshoreLibVLC, FarshoreVideoFailure>?

    init() {
        // Resolve by stable identifier so moving VLC does not break playback.
        applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc")
    }

    func load() -> Result<FarshoreLibVLC, FarshoreVideoFailure> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let result: Result<FarshoreLibVLC, FarshoreVideoFailure>
        do {
            guard let applicationURL else {
                throw FarshoreVideoFailure(code: "libvlc-unavailable", message: "VLC is not available to Farshore. Install VLC for embedded playback, or use Open With.")
            }
            result = .success(try FarshoreLibVLC(applicationURL: applicationURL))
        } catch let failure as FarshoreVideoFailure {
            result = .failure(failure)
        } catch {
            result = .failure(FarshoreVideoFailure(code: "libvlc-unavailable", message: "Embedded playback is unavailable. Use Open With."))
        }
        cached = result
        return result
    }
}

private func farshoreMountedVideoPath(_ path: String?) throws -> String {
    guard let path, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 16_384 else {
        throw FarshoreVideoFailure(code: "invalid-media-path", message: "Embedded playback requires a mounted Farshore file.")
    }
    let environment = ProcessInfo.processInfo.environment
    let root = environment["FARSHORE_ROOT"]
        ?? Bundle.main.object(forInfoDictionaryKey: "FarshoreDevelopmentRoot") as? String
        ?? FileManager.default.currentDirectoryPath
    let state = environment["FARSHORE_STATE"] ?? (root as NSString).appendingPathComponent(".runtime")
    let mounts = URL(fileURLWithPath: state, isDirectory: true)
        .appendingPathComponent("mounts", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(mounts.path + "/") else {
        throw FarshoreVideoFailure(code: "invalid-media-path", message: "Only files inside Farshore's mounted folders can play here.")
    }
    var filesystem = statfs()
    let status = file.path.withCString { statfs($0, &filesystem) }
    let mountpoint = withUnsafePointer(to: &filesystem.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    guard status == 0, filesystem.f_flags & UInt32(MNT_RDONLY) != 0,
          mountpoint.hasPrefix(mounts.path + "/"), file.path.hasPrefix(mountpoint + "/"),
          (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        throw FarshoreVideoFailure(code: "media-mount-unavailable", message: "The read-only mounted file is unavailable. Reconnect or use Open With.")
    }
    return file.path
}

private func farshoreLoopbackVideoURL(_ value: String) throws -> String {
    guard value.utf8.count <= 512, let components = URLComponents(string: value),
          components.scheme == "http", components.host == "127.0.0.1",
          let port = components.port, (1024...65535).contains(port),
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          components.percentEncodedPath == components.path,
          components.path.range(of: "^/media/[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil,
          let url = components.url else {
        throw FarshoreVideoFailure(code: "invalid-media-url", message: "Embedded playback requires a protected local Farshore stream.")
    }
    return url.absoluteString
}

private final class FarshoreVideoSession {
    private let queue = DispatchQueue(label: "dev.farshore.libvlc.player", qos: .userInitiated)
    private var renderingView: NSView?
    private var library: FarshoreLibVLC?
    private var instance: OpaquePointer?
    private var player: OpaquePointer?
    private var failure: FarshoreVideoFailure?
    private var disposed = false
    private var seekGeneration = 0
    private var knownLength: Int64 = 0

    init(path: String?, url: String? = nil, audioOnly: Bool = false, renderingView: NSView, loader: FarshoreLibVLCLoader) {
        self.renderingView = renderingView
        let drawable = Unmanaged.passUnretained(renderingView).toOpaque()
        queue.async { [self] in
            do {
                guard path == nil || url == nil else {
                    throw FarshoreVideoFailure(code: "invalid-media-source", message: "Choose one mounted file or protected local stream.")
                }
                let source = try url.map(farshoreLoopbackVideoURL) ?? farshoreMountedVideoPath(path)
                let library = try loader.load().get()
                self.library = library
                guard let instance = library.newInstance() else {
                    throw FarshoreVideoFailure(code: "libvlc-initialization", message: "VideoLAN could not initialize its decoder. Use Open With.")
                }
                self.instance = instance
                guard let player = library.createPlayer(instance) else {
                    throw FarshoreVideoFailure(code: "libvlc-initialization", message: "VideoLAN could not create a player. Use Open With.")
                }
                self.player = player
                let media = source.withCString {
                    url == nil ? library.createMedia(instance, $0) : library.createLocation(instance, $0)
                }
                guard let media else {
                    throw FarshoreVideoFailure(code: "media-unavailable", message: "VideoLAN could not open this media source. Use Open With.")
                }
                if audioOnly {
                    ":no-video".withCString { library.addMediaOption(media, $0) }
                }
                library.setMedia(player, media)
                library.releaseMedia(media)
                library.setDrawable(player, drawable)
                _ = library.setVolume(player, 80)
            } catch let failure as FarshoreVideoFailure {
                self.failure = failure
            } catch {
                failure = FarshoreVideoFailure(code: "media-unavailable", message: "Embedded playback is unavailable. Use Open With.")
            }
        }
    }

    func control(action: String, position: Double?, volume: Int?, reply: @escaping FlutterResult) {
        queue.async { [self] in
            if action == "stop" {
                // Even a failed initialization may have allocated a player.
                // An acknowledged stop always drains that input before the UI
                // releases its backend mount lease.
                seekGeneration += 1
                if let library, let player { library.stop(player) }
                finish(reply, ["accepted": true])
                return
            }
            if let failure {
                finish(reply, FlutterError(code: failure.code, message: failure.message, details: nil))
                return
            }
            guard !disposed, let library, let player else {
                finish(reply, FlutterError(code: "player-disposed", message: "This player is no longer available.", details: nil))
                return
            }
            switch action {
            case "play", "resume", "replay":
                let state = library.state(player)
                // LibVLC 3 keeps the exhausted input after EOF: play() can
                // report success while leaving the player in Ended forever.
                // Releasing that input through stop() makes replay real.
                if action == "replay" || state == 6 || state == 7 {
                    seekGeneration += 1
                    library.stop(player)
                } else if state == 4 {
                    library.pause(player, 0)
                    finish(reply, ["accepted": true])
                    return
                }
                if library.play(player) != 0 {
                    finish(reply, FlutterError(code: "playback-failed", message: "VideoLAN could not start playback. Use Open With.", details: nil))
                    return
                }
            case "pause": library.pause(player, 1)
            case "seek":
                guard let position, position.isFinite, (0...1).contains(position) else {
                    finish(reply, FlutterError(code: "invalid-position", message: "Seek position must be between 0 and 1.", details: nil))
                    return
                }
                seekGeneration += 1
                let state = library.state(player)
                if state == 6 && position == 1 {
                    finish(reply, ["accepted": true])
                    return
                }
                if state == 5 || state == 6 || state == 7 {
                    library.stop(player)
                    guard library.play(player) == 0 else {
                        finish(reply, FlutterError(code: "playback-failed", message: "VideoLAN could not restart playback for seeking. Use Open With.", details: nil))
                        return
                    }
                }
                seekWhenReady(position: Float(position), generation: seekGeneration, attempts: 200, reply: reply)
                return
            case "volume":
                guard let volume, (0...100).contains(volume) else {
                    finish(reply, FlutterError(code: "invalid-volume", message: "Volume must be between 0 and 100.", details: nil))
                    return
                }
                _ = library.setVolume(player, Int32(volume))
            default:
                finish(reply, FlutterError(code: "unknown-control", message: "Unsupported media control.", details: nil))
                return
            }
            finish(reply, ["accepted": true])
        }
    }

    private func seekWhenReady(position: Float, generation: Int, attempts: Int, reply: @escaping FlutterResult) {
        guard !disposed, generation == seekGeneration, let library, let player else {
            finish(reply, FlutterError(code: "seek-cancelled", message: "The seek was cancelled by another playback action.", details: nil))
            return
        }
        let state = library.state(player)
        if (state == 3 || state == 4) && library.isSeekable(player) != 0 {
            library.setPosition(player, position)
            finish(reply, ["accepted": true])
        } else if state == 7 || attempts == 0 {
            finish(reply, FlutterError(code: "seek-unavailable", message: "VideoLAN could not prepare this file for seeking. Try replaying it or use Open With.", details: nil))
        } else {
            // A restarted input cannot accept a seek while it is still
            // opening. Retry on the worker without blocking pause/stop/dispose.
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                seekWhenReady(position: position, generation: generation, attempts: attempts - 1, reply: reply)
            }
        }
    }

    func state(reply: @escaping FlutterResult) {
        queue.async { [self] in
            guard !disposed, let library, let player else {
                finish(reply, ["playing": false, "position": 0.0, "lengthMs": 0, "timeMs": 0,
                               "state": 7, "stateName": "error", "width": 0, "height": 0,
                               "error": failure?.message ?? "This player is no longer available."])
                return
            }
            let state = library.state(player)
            let names = ["nothing-special", "opening", "buffering", "playing", "paused", "stopped", "ended", "error"]
            let position = Double(library.position(player))
            let length = max(0, library.length(player))
            if length > 0 { knownLength = length }
            let ended = state == 6
            var width: UInt32 = 0
            var height: UInt32 = 0
            _ = library.videoSize(player, 0, &width, &height)
            var result: [String: Any] = [
                "playing": library.isPlaying(player) != 0,
                "position": ended ? 1 : (position.isFinite ? min(1, max(0, position)) : 0),
                "lengthMs": knownLength,
                "timeMs": ended && knownLength > 0 ? knownLength : max(0, library.time(player)),
                "state": state, "stateName": (0..<names.count).contains(Int(state)) ? names[Int(state)] : "error",
                "width": width, "height": height, "seekable": library.isSeekable(player) != 0,
            ]
            if let failure { result["error"] = failure.message }
            else if state == 7 { result["error"] = "VideoLAN could not decode this file. Use Open With." }
            finish(reply, result)
        }
    }

    func dispose() {
        queue.async { [self] in
            guard !disposed else { return }
            disposed = true
            seekGeneration += 1
            if let library {
                if let player {
                    // stop can wait for decoder/input threads. It must never
                    // block Flutter's main thread, which Cocoa vout also uses.
                    library.stop(player)
                    library.setDrawable(player, nil)
                    library.releasePlayer(player)
                }
                if let instance { library.releaseInstance(instance) }
            }
            player = nil
            instance = nil
            let renderingView = self.renderingView
            self.renderingView = nil
            // Release the last Swift-owned drawable reference on AppKit's
            // thread after decoder teardown, even if disposal began in deinit.
            DispatchQueue.main.async { renderingView?.removeFromSuperview() }
        }
    }

    private func finish(_ reply: @escaping FlutterResult, _ value: Any) {
        DispatchQueue.main.async { reply(value) }
    }
}

private final class FarshoreVideoView: NSView {
    let session: FarshoreVideoSession
    var onDispose: (() -> Void)?

    init(path: String?, url: String? = nil, audioOnly: Bool = false, loader: FarshoreLibVLCLoader) {
        let renderingView = NSView(frame: .zero)
        renderingView.wantsLayer = true
        renderingView.layer?.backgroundColor = NSColor.black.cgColor
        renderingView.autoresizingMask = [.width, .height]
        // The render target is a child, not this platform view. LibVLC may
        // retain its drawable; it must not prevent this outer view's disposal.
        session = FarshoreVideoSession(path: path, url: url, audioOnly: audioOnly, renderingView: renderingView, loader: loader)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(renderingView)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        session.dispose()
        onDispose?()
    }
}

private final class FarshoreWeakVideoView {
    weak var value: FarshoreVideoView?
    init(_ value: FarshoreVideoView) { self.value = value }
}

final class FarshoreVideoPlugin: NSObject, FlutterPlatformViewFactory {
    private let channel: FlutterMethodChannel
    private let loader = FarshoreLibVLCLoader()
    private var views: [Int64: FarshoreWeakVideoView] = [:]

    init(registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(name: "farshore/media", binaryMessenger: registrar.messenger)
        super.init()
        registrar.register(self, withId: "farshore/libvlc")
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, reply: result)
        }
    }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        let path = (args as? [String: Any])?["path"] as? String
        let url = (args as? [String: Any])?["url"] as? String
        let audioOnly = (args as? [String: Any])?["audioOnly"] as? Bool ?? false
        let view = FarshoreVideoView(path: path, url: url, audioOnly: audioOnly, loader: loader)
        view.onDispose = { [weak self] in self?.views.removeValue(forKey: viewId) }
        views[viewId] = FarshoreWeakVideoView(view)
        return view
    }

    private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
        if call.method == "availability" {
            let loader = self.loader
            DispatchQueue.global(qos: .userInitiated).async {
                let value: [String: Any]
                switch loader.load() {
                case .success(let library): value = ["available": true, "version": library.version, "engine": "LibVLC"]
                case .failure(let failure): value = ["available": false, "version": NSNull(), "engine": "LibVLC", "message": failure.message]
                }
                DispatchQueue.main.async { reply(value) }
            }
            return
        }
        guard call.method == "control" || call.method == "state" else {
            reply(FlutterMethodNotImplemented)
            return
        }
        guard let arguments = call.arguments as? [String: Any], let viewId = arguments["viewId"] as? NSNumber,
              let view = views[viewId.int64Value]?.value else {
            reply(FlutterError(code: "player-unavailable", message: "This embedded player is no longer available. Use Open With.", details: nil))
            return
        }
        if call.method == "state" { view.session.state(reply: reply); return }
        guard let action = arguments["action"] as? String else {
            reply(FlutterError(code: "invalid-control", message: "A media control action is required.", details: nil))
            return
        }
        view.session.control(action: action, position: (arguments["position"] as? NSNumber)?.doubleValue,
                             volume: (arguments["volume"] as? NSNumber)?.intValue, reply: reply)
    }
}
