import AppKit
import Darwin
import FlutterMacOS
import QuickLookUI
import UniformTypeIdentifiers

private struct FarshorePreviewFailure: Error {
    let code: String
    let message: String

    var flutterError: FlutterError {
        FlutterError(code: code, message: message, details: nil)
    }
}

private func isFarshorePreviewShortcut(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags
    if event.keyCode == 53 {
        return flags.intersection([.command, .control, .option, .shift]).isEmpty
    }
    let command = flags.contains(.command) || flags.contains(.control)
    guard !flags.contains(.option) else { return false }
    return command
        ? event.charactersIgnoringModifiers?.lowercased() == "l"
        : event.characters == "/"
}

private enum FarshorePreviewFile {
    static let maximumBytes: Int64 = 64 * 1024 * 1024

    static func validate(_ path: String?) throws -> URL {
        guard let path, path.hasPrefix("/"), path.utf8.count <= 16_384,
              !path.contains("\0") else {
            throw FarshorePreviewFailure(code: "preview-invalid-path", message: "The preview did not provide a managed local file.")
        }
        let environment = ProcessInfo.processInfo.environment
        let state: URL
        if let configured = environment["FARSHORE_STATE"], configured.hasPrefix("/") {
            state = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let root = environment["FARSHORE_ROOT"]
                ?? Bundle.main.object(forInfoDictionaryKey: "FarshoreDevelopmentRoot") as? String
                ?? FileManager.default.currentDirectoryPath
            state = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".runtime", isDirectory: true)
        }
        let managed = state.appendingPathComponent("previews", isDirectory: true).standardizedFileURL
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.path == path, file.path.hasPrefix(managed.path + "/") else {
            throw FarshorePreviewFailure(code: "preview-invalid-path", message: "The preview file is outside Farshore’s private preview cache.")
        }
        let relative = String(file.path.dropFirst(managed.path.count + 1))
        let resolved = file.resolvingSymlinksInPath()
        let expected = managed.resolvingSymlinksInPath().appendingPathComponent(relative)
        var metadata = stat()
        guard resolved.path == expected.path,
              lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_size > 0 else {
            throw FarshorePreviewFailure(code: "preview-invalid-file", message: "The preview file is missing, linked, or is not a regular private file.")
        }
        guard metadata.st_size <= maximumBytes else {
            throw FarshorePreviewFailure(code: "preview-too-large", message: "This file exceeds the 64 MiB embedded preview limit. Use Open With.")
        }
        // macOS has no public canPreview API for QLPreviewView. Restrict the
        // admitted families, then let the OS display its asynchronous preview
        // or unsupported-file presentation. Never admit HTML or arbitrary URLs.
        let ext = file.pathExtension.lowercased()
        let documents: Set<String> = [
            "pdf", "doc", "docx", "dot", "dotx", "xls", "xlsx", "xlt", "xltx",
            "ppt", "pptx", "pps", "ppsx", "pot", "potx", "odt", "ods", "odp",
            "pages", "numbers", "key", "rtf",
        ]
        guard UTType(filenameExtension: ext)?.conforms(to: .image) == true || documents.contains(ext) else {
            throw FarshorePreviewFailure(code: "preview-unsupported", message: "This file type does not have an embedded document preview. Use Open With.")
        }
        return file
    }
}

private final class FarshorePreviewView: NSView {
    private let path: String?
    private var preview: QLPreviewView?
    private var item: NSURL?
    private var failure: FarshorePreviewFailure?
    private(set) var isClosed = false
    var onClosed: (() -> Void)?

    init(path: String?) {
        self.path = path
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        // Factory creation is deliberately inert. Dart records the view ID
        // before calling open, so late view creation cannot start a reader
        // after the backend has already released a canceled preview lease.
        do { _ = try FarshorePreviewFile.validate(path) }
        catch let error as FarshorePreviewFailure { failure = error }
        catch { failure = FarshorePreviewFailure(code: "preview-invalid-file", message: "The preview file could not be validated.") }
    }

    required init?(coder: NSCoder) { nil }

    func open() throws {
        guard !isClosed else {
            throw FarshorePreviewFailure(code: "preview-closed", message: "This preview has already closed.")
        }
        if let failure { throw failure }
        guard preview == nil else { return }
        let file = try FarshorePreviewFile.validate(path)
        guard let view = QLPreviewView(frame: bounds, style: .normal) else {
            throw FarshorePreviewFailure(code: "preview-unavailable", message: "macOS could not create an embedded preview. Use Open With.")
        }
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.autoresizingMask = [.width, .height]
        let item = file as NSURL
        self.item = item
        preview = view
        addSubview(view)
        view.previewItem = item
    }

    var state: [String: Any] {
        if isClosed { return ["status": "closed"] }
        if let failure { return ["status": "failed", "errorCode": failure.code, "error": failure.message] }
        return ["status": preview == nil ? "waiting" : "attached"]
    }

    func containsResponder(_ responder: NSResponder?) -> Bool {
        guard !isClosed, preview != nil, let view = responder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // Public Quick Look contract: close releases the current preview item
        // and prevents further assignments. It has no asynchronous completion
        // callback. These are bounded local snapshots, never live mount paths.
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        item = nil
        onClosed?()
        onClosed = nil
    }

    deinit {
        // Flutter/AppKit normally destroys views on main. Retain only the
        // resources in an off-main teardown until main has actually closed
        // them; do not acknowledge disposal before that close occurs.
        if Thread.isMainThread {
            close()
        } else {
            let view = preview
            let closed = onClosed
            DispatchQueue.main.async {
                view?.close()
                view?.removeFromSuperview()
                closed?()
            }
        }
    }
}

private final class FarshoreWeakPreviewView {
    weak var value: FarshorePreviewView?
    init(_ value: FarshorePreviewView) { self.value = value }
}

final class FarshorePreviewPlugin: NSObject, FlutterPlatformViewFactory {
    private let channel: FlutterMethodChannel
    private weak var controller: FlutterViewController?
    private var views: [Int64: FarshoreWeakPreviewView] = [:]
    private var closedIDs: [Int64] = []
    private var keyMonitor: Any?
    private var forwardedKeys: Set<UInt16> = []

    init(registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(name: "farshore/preview", binaryMessenger: registrar.messenger)
        controller = registrar.viewController as? FlutterViewController
        super.init()
        registrar.register(self, withId: "farshore/file_preview")
        channel.setMethodCallHandler { [weak self] call, reply in
            self?.handle(call, reply: reply)
        }
        // Quick Look providers can consume native key events before Flutter's
        // responder receives them. This is an in-process monitor, scoped to
        // the existing window and first responder inside our open preview.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return routeKey(event)
        }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    private func routeKey(_ event: NSEvent) -> NSEvent? {
        guard let controller else { return event }
        if event.type == .keyUp, forwardedKeys.remove(event.keyCode) != nil {
            controller.keyUp(with: event)
            return nil
        }
        guard event.type == .keyDown,
              let window = event.window, window === controller.view.window,
              views.values.contains(where: { $0.value?.containsResponder(window.firstResponder) == true }),
              isFarshorePreviewShortcut(event) else { return event }
        // Typing a slash in a native provider's editable search field should
        // remain ordinary text input. The explicit location shortcut is global.
        if event.characters == "/", !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
           let text = window.firstResponder as? NSTextView, text.isEditable { return event }
        forwardedKeys.insert(event.keyCode)
        controller.keyDown(with: event)
        return nil // Never also deliver this event to the native provider.
    }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        let view = FarshorePreviewView(path: (args as? [String: Any])?["path"] as? String)
        closedIDs.removeAll { $0 == viewId }
        view.onClosed = { [weak self] in
            guard let self else { return }
            views.removeValue(forKey: viewId)
            if !closedIDs.contains(viewId) { closedIDs.append(viewId) }
            if closedIDs.count > 128 { closedIDs.removeFirst(closedIDs.count - 128) }
        }
        views[viewId] = FarshoreWeakPreviewView(view)
        return view
    }

    private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
        if call.method == "availability" {
            reply(["available": true, "engine": "Quick Look", "supportsReadiness": false])
            return
        }
        guard ["open", "state", "close"].contains(call.method) else {
            reply(FlutterMethodNotImplemented)
            return
        }
        guard let arguments = call.arguments as? [String: Any], let id = arguments["viewId"] as? NSNumber else {
            reply(FlutterError(code: "preview-invalid-view", message: "An embedded preview identifier is required.", details: nil))
            return
        }
        let viewId = id.int64Value
        if closedIDs.contains(viewId) {
            if call.method == "close" { reply(["closed": true]); return }
            if call.method == "state" { reply(["status": "closed"]); return }
        }
        guard let view = views[viewId]?.value else {
            reply(FlutterError(code: "preview-unavailable", message: "This embedded preview is no longer available.", details: nil))
            return
        }
        if call.method == "close" { view.close(); reply(["closed": true]); return }
        if call.method == "state" { reply(view.state); return }
        do {
            try view.open()
            reply(view.state)
        } catch let error as FarshorePreviewFailure {
            reply(error.flutterError)
        } catch {
            reply(FlutterError(code: "preview-failed", message: "macOS could not display this file. Use Open With.", details: nil))
        }
    }
}
