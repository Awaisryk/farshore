import AppKit
@preconcurrency import FlutterMacOS

// Isolated release-framework regression. No windows are ordered onscreen, and
// the launcher supplies a private stdio fixture instead of the real SSH bridge.
@main struct AccessibilitySmoke {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let dartBundle = Bundle(url: frameworks.appendingPathComponent("App.framework")) else { exit(2) }
        let controller = FlutterViewController(project: FlutterDartProject(precompiledDartBundle: dartBundle))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1380, height: 880),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: 1380, height: 880)
        view.layoutSubtreeIfNeeded()
        let engine = controller.engine
        guard engine.run(withEntrypoint: nil), engine.responds(to: NSSelectorFromString("setSemanticsEnabled:")) else { exit(2) }
        let lifecycle = FlutterBasicMessageChannel(name: "flutter/lifecycle", binaryMessenger: engine.binaryMessenger,
                                                  codec: FlutterStringCodec.sharedInstance())
        let checkPalette = ProcessInfo.processInfo.environment["FARSHORE_AX_PALETTE"] == "1"
        let checkHome = ProcessInfo.processInfo.environment["FARSHORE_AX_HOME"] == "1"

        // Flutter 3.47 exposes no public semantics-enable setter. This test-only
        // KVC call exercises the same engine property used by its native AX
        // notification handler. Production runner code never calls it.
        func semantics(_ enabled: Bool) {
            engine.setValue(enabled, forKey: "semanticsEnabled")
            print("AX_SEMANTICS=\(enabled)")
            fflush(stdout)
        }
        func text(_ item: NSObject, _ key: String) -> String {
            item.responds(to: NSSelectorFromString(key)) ? item.value(forKey: key) as? String ?? "" : ""
        }
        func nodes() -> [NSObject] {
            var pending: [NSObject] = [view]
            var seen = Set<ObjectIdentifier>()
            var result: [NSObject] = []
            while let item = pending.popLast(), result.count < 2000 {
                guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
                result.append(item)
                if item.responds(to: NSSelectorFromString("accessibilityChildren")),
                   let children = item.value(forKey: "accessibilityChildren") as? [NSObject] {
                    pending.append(contentsOf: children.reversed())
                }
            }
            return result
        }
        func finish(_ ok: Bool, _ reason: String) -> Never {
            print("AX_SMOKE_OK=\(ok) REASON=\(reason) VISIBLE_WINDOW=\(window.isVisible)")
            fflush(stdout)
            engine.shutDownEngine()
            exit(ok && !window.isVisible ? 0 : 1)
        }
        func snapshot(_ phase: String, requireHost: Bool = true) {
            let tree = nodes()
            let host = tree.contains { text($0, "accessibilityLabel").contains("AX fixture host") }
            let rootRole = tree.dropFirst(2).first.map { text($0, "accessibilityRole") } ?? ""
            print("AX_PHASE=\(phase) NODES=\(tree.count) ROOT_ROLE=\(rootRole) FIXTURE_HOST=\(host) ENGINE_SEMANTICS=\(engine.value(forKey: "semanticsEnabled") ?? "nil")")
            fflush(stdout)
            if tree.count <= 2 || rootRole.isEmpty || (requireHost && !host) { finish(false, "missing-native-semantics") }
        }
        func hasLabel(_ value: String) -> Bool {
            nodes().contains { text($0, "accessibilityLabel").contains(value) }
        }
        func semanticsReady(requireHost: Bool = true) -> Bool {
            let tree = nodes()
            let rootRole = tree.dropFirst(2).first.map { text($0, "accessibilityRole") } ?? ""
            return tree.count > 2 && !rootRole.isEmpty && (!requireHost || tree.contains {
                text($0, "accessibilityLabel").contains("AX fixture host")
            })
        }
        func key(_ characters: String, code: UInt16) {
            // Deliver only to this component's NSResponder. This neither posts
            // OS keyboard input nor changes the user's foreground application.
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code) else { finish(false, "fixture-key-construction") }
                if type == .keyDown { controller.keyDown(with: event) } else { controller.keyUp(with: event) }
            }
        }
        func recentPaths() -> [String] {
            var result: [String] = []
            for item in nodes() {
                let label = text(item, "accessibilityLabel")
                for index in 1...5 {
                    let path = "/fixture/recent-\(index)"
                    if label.contains(path) && !result.contains(path) { result.append(path) }
                }
            }
            return result
        }
        func paletteSnapshot(_ phase: String, requireFive: Bool) {
            let recent = recentPaths()
            print("AX_PALETTE_DEBUG_PHASE=\(phase) CLOSE_LABEL=\(hasLabel("Close path launcher")) TITLE_LABEL=\(hasLabel("Go to folder")) RECENT_ROWS=\(recent.count) NODES=\(nodes().count)")
            guard hasLabel("Close path launcher") else { finish(false, "path-palette-not-open") }
            guard !requireFive || recent.count == 5 else { finish(false, "missing-five-recent-destinations") }
            print("AX_PALETTE_PHASE=\(phase) RECENT_ROWS=\(recent.count) NATIVE_NODES=\(nodes().count)")
            fflush(stdout)
        }
        func fixtureCalls(_ method: String) -> Int {
            guard let state = ProcessInfo.processInfo.environment["FARSHORE_STATE"],
                  let log = try? String(contentsOfFile: state + "/calls.jsonl", encoding: .utf8) else { return 0 }
            return log.split(separator: "\n").filter { line in
                guard let data = String(line).data(using: .utf8),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return request["method"] as? String == method
            }.count
        }
        func homeVisible() -> Bool { hasLabel("Your remote workspace.") }
        func homeReady(returned: Bool = false) -> Bool {
            homeVisible() && hasLabel("Home") && hasLabel("Open server AX fixture host") && !recentPaths().isEmpty
                && (!returned || hasLabel("Resume AX fixture host at /fixture/recent-5"))
        }
        func homeSnapshot(_ phase: String, initial: Bool = false) {
            guard homeVisible(), hasLabel("Home"), hasLabel("Open server AX fixture host"),
                  !recentPaths().isEmpty else { finish(false, "missing-home-content") }
            if initial && fixtureCalls("list") != 0 { finish(false, "home-caused-unsolicited-browse") }
            if !initial {
                guard hasLabel("Resume AX fixture host at /fixture/recent-5"), fixtureCalls("list") == 1 else {
                    finish(false, "home-did-not-preserve-workspace")
                }
            }
            print("AX_HOME_PHASE=\(phase) RECENT_ROWS=\(recentPaths().count) LIST_CALLS=\(fixtureCalls("list"))")
            fflush(stdout)
        }
        func activate(_ label: String) {
            guard let item = nodes().first(where: { text($0, "accessibilityLabel").contains(label) }) else {
                finish(false, "home-action-missing")
            }
            let legacy = NSSelectorFromString("accessibilityPerformAction:")
            let modern = NSSelectorFromString("accessibilityPerformPress")
            if item.responds(to: legacy) {
                typealias Action = @convention(c) (AnyObject, Selector, NSString) -> Void
                let action = unsafeBitCast(item.method(for: legacy), to: Action.self)
                action(item, legacy, "AXPress")
            } else if item.responds(to: modern) {
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                let press = unsafeBitCast(item.method(for: modern), to: Press.self)
                _ = press(item, modern)
            } else { finish(false, "home-action-unavailable") }
            // Confirm the resulting UI/state in a later phase rather than
            // trusting an asynchronous native action's immediate return value.
            print("AX_COMPONENT_ACTION=\(label) ROLE=\(text(item, "accessibilityRole"))")
            fflush(stdout)
        }
        semantics(true)
        let started = ProcessInfo.processInfo.systemUptime
        var step = 0
        var phaseStarted = started
        func advance(to next: Int? = nil) {
            step = next ?? step + 1
            phaseStarted = ProcessInfo.processInfo.systemUptime
        }
        var resumed = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
            if !resumed {
                // Hidden windows otherwise pause Dart frame/semantics updates.
                // Resume only this isolated engine through the public channel;
                // keep the actual NSWindow unshown and the app prohibited.
                lifecycle.sendMessage("AppLifecycleState.resumed")
                resumed = true
            }
            view.layoutSubtreeIfNeeded()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let phaseElapsed = ProcessInfo.processInfo.systemUptime - phaseStarted
            // Repeated reads exercise the actual AppKit bridge while discovery
            // and incremental Flutter semantics updates are being delivered.
            _ = nodes()
            if window.isVisible { finish(false, "unexpected-visible-window") }
            // A hidden engine can deliver the dialog and native semantics in
            // separate frames. Wait for the actual result of each one-shot
            // action; absolute elapsed times used to fail at 4.8s while the
            // route was still publishing its native accessibility subtree.
            // Every phase and the complete run retain hard deadlines.
            switch step {
            case 0 where phaseElapsed >= 0.2 && semanticsReady(requireHost: false):
                snapshot("startup", requireHost: false)
                advance()
            case 1 where semanticsReady() && (!checkHome || homeReady()):
                snapshot("discovery")
                if checkHome { homeSnapshot("startup", initial: true) }
                advance()
            case 2 where phaseElapsed >= 0.3:
                semantics(false)
                advance()
            case 3 where phaseElapsed >= 0.2 && nodes().count <= 2:
                let disabledNodes = nodes().count
                print("AX_DISABLED_NODES=\(disabledNodes)")
                if disabledNodes > 2 { finish(false, "stale-disabled-semantics") }
                semantics(true)
                advance()
            case 4 where phaseElapsed >= 0.3 && semanticsReady() && (!checkHome || homeReady()):
                snapshot("reenabled")
                if checkHome {
                    homeSnapshot("reenabled", initial: true)
                    key("/", code: 44)
                    advance(to: 11)
                } else if checkPalette {
                    key("/", code: 44)
                    advance()
                } else { finish(true, "native-ax-startup-discovery-toggle") }
            case 5 where phaseElapsed >= 0.4 && hasLabel("Close path launcher") && recentPaths().count == 5:
                paletteSnapshot("slash-open", requireFive: true)
                // Up from no selection chooses the oldest visible destination.
                // Exercise the palette's real keyboard path, then verify its
                // accepted list/history calls through the isolated fixture.
                key("\u{f700}", code: 126)
                key("\r", code: 36)
                advance()
            case 6 where phaseElapsed >= 0.3 && !hasLabel("Close path launcher") && semanticsReady()
                    && fixtureCalls("list") == 1 && fixtureCalls("record_path_visit") == 1:
                if hasLabel("Close path launcher") { finish(false, "palette-not-closed-after-navigation") }
                snapshot("recent-navigation")
                key("/", code: 44)
                advance()
            case 7 where phaseElapsed >= 0.4 && hasLabel("Close path launcher") && recentPaths().count == 5:
                paletteSnapshot("reopened", requireFive: true)
                guard recentPaths().first == "/fixture/recent-5" else { finish(false, "successful-recent-not-first") }
                key("\u{1b}", code: 53)
                advance()
            case 8 where phaseElapsed >= 0.3 && !hasLabel("Close path launcher") && semanticsReady():
                if hasLabel("Close path launcher") { finish(false, "palette-escape-did-not-close") }
                semantics(false)
                advance()
            case 9 where phaseElapsed >= 0.2 && nodes().count <= 2:
                if nodes().count > 2 { finish(false, "stale-post-palette-disabled-semantics") }
                semantics(true)
                advance()
            case 10 where phaseElapsed >= 0.3 && semanticsReady():
                snapshot("post-palette-reenabled")
                finish(true, "native-ax-path-palette-recents-navigation")
            case 11 where phaseElapsed >= 0.4 && hasLabel("Close path launcher") && recentPaths().count == 5:
                paletteSnapshot("home-launcher", requireFive: true)
                key("\u{f700}", code: 126)
                key("\r", code: 36)
                advance()
            case 12 where phaseElapsed >= 0.3 && !homeVisible() && !hasLabel("Close path launcher")
                    && hasLabel("recent-5") && fixtureCalls("list") == 1 && fixtureCalls("record_path_visit") == 1:
                guard !homeVisible(), !hasLabel("Close path launcher"), hasLabel("recent-5"),
                      fixtureCalls("list") == 1 else { finish(false, "home-folder-navigation-failed") }
                snapshot("home-folder")
                activate("Go to Farshore Home")
                advance()
            case 13 where phaseElapsed >= 0.3 && homeReady(returned: true):
                homeSnapshot("returned-home")
                activate("Resume AX fixture host at /fixture/recent-5")
                advance()
            case 14 where phaseElapsed >= 0.3 && !homeVisible() && hasLabel("recent-5") && semanticsReady():
                guard !homeVisible(), hasLabel("recent-5"), fixtureCalls("list") == 1 else {
                    finish(false, "home-resume-lost-workspace-or-refetched")
                }
                snapshot("resumed-folder")
                activate("Go to Farshore Home")
                advance()
            case 15 where phaseElapsed >= 0.3 && homeReady(returned: true):
                homeSnapshot("returned-again")
                semantics(false)
                advance()
            case 16 where phaseElapsed >= 0.2 && nodes().count <= 2:
                if nodes().count > 2 { finish(false, "stale-home-disabled-semantics") }
                semantics(true)
                advance()
            case 17 where phaseElapsed >= 0.3 && homeReady(returned: true) && semanticsReady():
                homeSnapshot("home-reenabled")
                finish(true, "native-ax-home-navigation-preservation")
            default: break
            }
            if phaseElapsed > 6 || elapsed > 30 {
                print("AX_WAIT_TIMEOUT STEP=\(step) PHASE_SECONDS=\(phaseElapsed) NODES=\(nodes().count) CLOSE_LABEL=\(hasLabel("Close path launcher")) HOME=\(homeVisible()) LIST_CALLS=\(fixtureCalls("list"))")
                finish(false, "bounded-semantic-wait-deadline")
            }
            }
        }
        withExtendedLifetime(timer) { application.run() }
    }
}
