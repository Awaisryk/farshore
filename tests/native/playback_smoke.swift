// Concatenated after native/FarshoreVideo.swift by test-native-playback.sh.
// This exercises the actual private player session without changing its API.
// Input is a private prepare_media JSON manifest; capability URLs are never
// included in test output. Use a seekable video at least four seconds long.
private func playbackSmokeReport(_ report: [String: Any], exitCode: Int32) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(exitCode)
}

private final class FarshoreNativePlaybackSmoke {
    private let window: NSWindow
    private let view: FarshoreVideoView
    private let legacyActions: Bool
    private var finished = false
    private var observations: [[String: Any]] = []
    private var checks: [String] = []
    private var pausedTime: Int64 = 0

    init(url: String, legacyActions: Bool, audioOnly: Bool = false) {
        self.legacyActions = legacyActions
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 480, height: 270),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        view = FarshoreVideoView(path: nil, url: url, audioOnly: audioOnly, loader: FarshoreLibVLCLoader())
        window.contentView = view
        // No activation or keyboard focus; do not interfere with running apps.
        window.orderBack(nil)
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 70) { [self] in
            finish(false, "Playback smoke exceeded its 70-second deadline.")
        }
        command("volume", volume: 0) { [self] in
            command("play") { [self] in
                wait("initial-play", seconds: 15, until: { state in
                    self.playing(state) && self.time(state) >= 1000
                }) { [self] _ in pause() }
            }
        }
    }

    private func pause() {
        command("pause") { [self] in
            wait("paused-before", until: { self.code($0) == 4 }) { [self] state in
                pausedTime = time(state)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [self] in
                    snapshot("paused-after") { [self] state in
                        guard code(state) == 4, abs(time(state) - pausedTime) <= 100 else {
                            finish(false, "Pause did not hold the playback clock.")
                            return
                        }
                        checks.append("pause-clock-stable")
                        resume()
                    }
                }
            }
        }
    }

    private func resume() {
        command(legacyActions ? "play" : "resume") { [self] in
            wait("resumed", until: { self.playing($0) && self.time($0) >= self.pausedTime + 500 }) { [self] _ in
                checks.append("resume-clock-advanced")
                reachEnd("ended-before-replay") { [self] _ in replay() }
            }
        }
    }

    private func replay() {
        let awaitReplay: () -> Void = { [self] in
            wait("replayed", seconds: 12, until: { state in
                self.playing(state) && self.time(state) >= 500 && self.position(state) < 0.5
            }) { [self] _ in
                checks.append("eof-replay-clock-advanced")
                reachEnd("ended-before-seek") { [self] _ in seekFromEnd() }
            }
        }
        if legacyActions {
            // Exact sequence used by the original Flutter play button. Before
            // the fix it stayed Ended, time ~7.7s, with reported position zero.
            command("seek", position: 0) { [self] in command("play", then: awaitReplay) }
        } else {
            command("replay", then: awaitReplay)
        }
    }

    private func reachEnd(_ label: String, then next: @escaping ([String: Any]) -> Void) {
        command("seek", position: 0.88) { [self] in
            wait(label, until: { self.code($0) == 6 }) { [self] state in
                let length = (state["lengthMs"] as? NSNumber)?.int64Value ?? 0
                guard length >= 4000, position(state) == 1, time(state) == length else {
                    finish(false, "Ended playback did not report a complete timeline.")
                    return
                }
                if !checks.contains("ended-timeline-complete") { checks.append("ended-timeline-complete") }
                next(state)
            }
        }
    }

    private func seekFromEnd() {
        command("seek", position: 0.5) { [self] in
            wait("sought-from-eof", until: { state in
                self.playing(state) && self.position(state) >= 0.45 && self.position(state) < 0.85
            }) { [self] _ in
                checks.append("eof-seek-restarted-at-target")
                finish(true, "Pause, resume, replay, and seeking after EOF passed.")
            }
        }
    }

    private func command(_ action: String, position: Double? = nil, volume: Int? = nil,
                         then next: @escaping () -> Void) {
        guard !finished else { return }
        view.session.control(action: action, position: position, volume: volume) { [self] result in
            guard !finished else { return }
            if let error = result as? FlutterError { finish(false, "Native command failed: \(error.code)") }
            else { next() }
        }
    }

    private func snapshot(_ label: String, then next: @escaping ([String: Any]) -> Void) {
        view.session.state { [self] result in
            guard !finished else { return }
            guard var state = result as? [String: Any], state["error"] == nil else {
                finish(false, "The native player reported a playback error.")
                return
            }
            state["label"] = label
            observations.append(state)
            next(state)
        }
    }

    private func wait(_ label: String, seconds: Double = 8,
                      until predicate: @escaping ([String: Any]) -> Bool,
                      then next: @escaping ([String: Any]) -> Void) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        func poll() {
            guard !finished else { return }
            view.session.state { [self] result in
                guard !finished else { return }
                guard var state = result as? [String: Any], state["error"] == nil else {
                    finish(false, "The native player reported a playback error.")
                    return
                }
                if predicate(state) {
                    state["label"] = label
                    observations.append(state)
                    next(state)
                } else if Date() >= deadline {
                    state["label"] = label + "-timeout"
                    observations.append(state)
                    finish(false, "Timed out waiting for \(label).")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
                }
            }
        }
        poll()
    }

    private func time(_ state: [String: Any]) -> Int64 { (state["timeMs"] as? NSNumber)?.int64Value ?? 0 }
    private func position(_ state: [String: Any]) -> Double { (state["position"] as? NSNumber)?.doubleValue ?? 0 }
    private func code(_ state: [String: Any]) -> Int { (state["state"] as? NSNumber)?.intValue ?? -1 }
    private func playing(_ state: [String: Any]) -> Bool { state["playing"] as? Bool == true && code(state) == 3 }

    private func finish(_ passed: Bool, _ message: String) {
        guard !finished else { return }
        finished = true
        view.session.control(action: "stop", position: nil, volume: nil) { [self] result in
            window.orderOut(nil)
            let stopped = !(result is FlutterError)
            playbackSmokeReport(["passed": passed && stopped, "message": message,
                                 "legacyActions": legacyActions, "checks": checks,
                                 "states": observations, "stopAcknowledged": stopped],
                                exitCode: passed && stopped ? 0 : 1)
        }
    }
}

private let playbackArguments = CommandLine.arguments
guard playbackArguments.count == 2 || (playbackArguments.count == 3 && playbackArguments[2] == "--legacy-actions"),
      let playbackData = try? Data(contentsOf: URL(fileURLWithPath: playbackArguments[1])), playbackData.count <= 65_536,
      let playbackManifest = try? JSONSerialization.jsonObject(with: playbackData) as? [String: Any],
      let playbackURL = playbackManifest["streamUrl"] as? String else {
    playbackSmokeReport(["passed": false, "message": "Provide a private prepare_media JSON manifest containing streamUrl."], exitCode: 2)
}
private let playbackApplication = NSApplication.shared
playbackApplication.setActivationPolicy(.prohibited)
private let playbackSmoke = FarshoreNativePlaybackSmoke(url: playbackURL, legacyActions: playbackArguments.count == 3,
    audioOnly: playbackManifest["audioOnly"] as? Bool ?? false)
playbackSmoke.start()
playbackApplication.run()
