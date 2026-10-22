import AppKit
import FlutterMacOS

// This development runner deliberately uses only the macOS Command Line Tools.
// Flutter's public embedder API loads the standard App.framework asset bundle.
final class FarshoreApplicationDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var videoPlugin: FarshoreVideoPlugin?
    private var previewPlugin: FarshorePreviewPlugin?
    private var lifecycleChannel: FlutterMethodChannel?
    private var terminating = false
    private var terminationReplied = false
    private var terminationTimeout: DispatchWorkItem?
    private var terminationAttempt = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let dartBundle = Bundle(url: frameworks.appendingPathComponent("App.framework")) else {
            let alert = NSAlert()
            alert.messageText = "Farshore could not load its interface"
            alert.informativeText = "Rebuild the application with scripts/build-app.sh."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let project = FlutterDartProject(precompiledDartBundle: dartBundle)
        let controller = FlutterViewController(project: project)
        videoPlugin = FarshoreVideoPlugin(registrar: controller.registrar(forPlugin: "FarshoreVideo"))
        previewPlugin = FarshorePreviewPlugin(registrar: controller.registrar(forPlugin: "FarshorePreview"))
        lifecycleChannel = FlutterMethodChannel(name: "farshore/lifecycle", binaryMessenger: controller.registrar(forPlugin: "FarshoreLifecycle").messenger)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Farshore"
        window.minSize = NSSize(width: 920, height: 620)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.center()
        window.setFrameAutosaveName("FarshoreMainWindow")
        self.window = window
        installMenus()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        let aliases = hostsWithExternalFiles()
        if !aliases.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "External files may still be open"
            alert.informativeText = "Applications may still be reading files from \(aliases.joined(separator: ", ")). Quitting Farshore keeps these mounted folders available. When you are finished, close the files in those applications, then eject the volumes in Finder."
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\r"
            let quit = alert.addButton(withTitle: "Quit and Keep Files Available")
            quit.keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn else {
                window?.makeKeyAndOrderFront(nil)
                return .terminateCancel
            }
        }
        guard let lifecycleChannel else { return .terminateNow }
        terminating = true
        terminationAttempt += 1
        let attempt = terminationAttempt
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishTermination(sender, attempt: attempt, saved: false)
        }
        terminationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        lifecycleChannel.invokeMethod("flushWorkspace", arguments: nil) { [weak self] result in
            DispatchQueue.main.async {
                self?.finishTermination(sender, attempt: attempt, saved: result as? Bool == true)
            }
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication, attempt: Int, saved: Bool) {
        guard terminating, attempt == terminationAttempt, !terminationReplied else { return }
        terminationReplied = true
        terminationTimeout?.cancel()
        terminationTimeout = nil
        if saved {
            sender.reply(toApplicationShouldTerminate: true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The workspace could not be saved"
        alert.informativeText = "Cancel to keep Farshore open and retry saving, or quit without saving the latest tabs and settings. External mounted files remain available."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: "Quit Without Saving")
        quit.keyEquivalent = ""
        let shouldQuit = alert.runModal() == .alertSecondButtonReturn
        if !shouldQuit {
            terminating = false
            terminationReplied = false
            window?.makeKeyAndOrderFront(nil)
        }
        sender.reply(toApplicationShouldTerminate: shouldQuit)
    }

    private func hostsWithExternalFiles() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let state: URL
        if let path = environment["FARSHORE_STATE"], !path.isEmpty {
            state = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let root = environment["FARSHORE_ROOT"]
                ?? Bundle.main.object(forInfoDictionaryKey: "FarshoreDevelopmentRoot") as? String
                ?? FileManager.default.currentDirectoryPath
            state = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".runtime", isDirectory: true)
        }
        let states = [state] + FarshoreRuntime.legacyStates(state: state)
        var aliases: [String] = []
        for state in states {
        let registry = state.appendingPathComponent("mount-registry.json")
        // This is a small local manifest. Never follow an unexpectedly large
        // file into an unbounded read on the application thread.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: registry.path),
              let size = attributes[.size] as? NSNumber, size.int64Value <= 1_048_576,
              let data = try? Data(contentsOf: registry),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1,
              let mounts = object["mounts"] as? [[String: Any]] else { continue }

        aliases.append(contentsOf: mounts.filter { $0["external"] as? Bool == true }.map { mount -> String in
            if let alias = mount["alias"] as? String, !alias.isEmpty { return alias }
            if let host = mount["hostId"] as? String, !host.isEmpty { return host }
            return "a remote host"
        })
        }
        return Set(aliases).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func installMenus() {
        let bar = NSMenu()
        let application = NSMenu(title: "Farshore")
        application.addItem(withTitle: "About Farshore", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Farshore", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = application.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Farshore", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        append(application, to: bar)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        append(edit, to: bar)

        let view = NSMenu(title: "View")
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        append(view, to: bar)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        append(windowMenu, to: bar)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = bar
    }

    private func append(_ menu: NSMenu, to bar: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }
}

@main
struct FarshoreApplication {
    @MainActor
    static func main() {
        let selfCheck = CommandLine.arguments.contains("--runtime-self-check")
        do { try FarshoreRuntime.configure() }
        catch {
            if selfCheck {
                print("{\"ok\":false,\"error\":\"runtime-configuration-failed\"}")
                exit(1)
            }
            _ = NSApplication.shared
            let alert = NSAlert()
            alert.messageText = "Farshore could not load its local runtime"
            alert.informativeText = "The application bundle or its private storage is unavailable. Reinstall Farshore or check your local storage permissions."
            alert.runModal()
            return
        }
        if selfCheck {
            let environment = ProcessInfo.processInfo.environment
            let manager = FileManager.default
            let checks = [
                "python": manager.isExecutableFile(atPath: environment["FARSHORE_PYTHON"] ?? ""),
                "bridge": manager.fileExists(atPath: environment["FARSHORE_BRIDGE_SCRIPT"] ?? ""),
                "native": manager.isExecutableFile(atPath: environment["FARSHORE_NATIVE"] ?? ""),
                "rclone": manager.isExecutableFile(atPath: environment["FARSHORE_RCLONE"] ?? ""),
                "notices": manager.fileExists(atPath: environment["FARSHORE_NOTICES"] ?? ""),
            ]
            let ok = checks.values.allSatisfy { $0 }
            let data = try! JSONSerialization.data(withJSONObject: ["ok": ok, "portable": Bundle.main.object(forInfoDictionaryKey: "FarshorePortableRuntime") as? Bool == true, "checks": checks])
            print(String(data: data, encoding: .utf8)!)
            if !ok { exit(1) }
            return
        }
        let application = NSApplication.shared
        let delegate = FarshoreApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
