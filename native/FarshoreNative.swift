import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A local, one-request-per-process adapter. Only `open` and
// `choose-application` launch applications or display user interface.
// Version the envelope before making incompatible protocol changes.
private let protocolVersion = 1
private let maximumSourceBytes = 64 * 1024 * 1024
private let maximumSourcePixels: Int64 = 80_000_000

private struct Failure: Error {
    let code: String
    let message: String
    let exitCode: Int32
    let details: [String: Any]?

    init(_ code: String, _ message: String, exitCode: Int32 = 1, details: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
        self.details = details
    }
}

private func emit(_ value: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    } catch {
        FileHandle.standardOutput.write(Data("{\"version\":1,\"ok\":false,\"error\":{\"code\":\"encoding-failed\",\"message\":\"Could not encode helper response.\"}}\n".utf8))
        exit(1)
    }
}

private func parseOptions(_ arguments: ArraySlice<String>, allowed: Set<String>) throws -> [String: String] {
    guard arguments.count <= 32, arguments.allSatisfy({ $0.utf8.count <= 16_384 }) else {
        throw Failure("invalid-arguments", "Command arguments exceed protocol limits.", exitCode: 2)
    }
    var result: [String: String] = [:]
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let name = arguments[index]
        guard allowed.contains(name), result[name] == nil else {
            throw Failure("invalid-arguments", "Unknown or repeated command option.", exitCode: 2)
        }
        index += 1
        guard index < arguments.endIndex else {
            throw Failure("invalid-arguments", "Missing value for \(name).", exitCode: 2)
        }
        result[name] = arguments[index]
        index += 1
    }
    return result
}

private func absoluteURL(_ path: String?, option: String) throws -> URL {
    guard let path, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 16_384 else {
        throw Failure("invalid-path", "\(option) requires an absolute local filesystem path.", exitCode: 2)
    }
    return URL(fileURLWithPath: path).standardizedFileURL
}

private func inputFile(_ path: String?) throws -> URL {
    let url = try absoluteURL(path, option: "--file")
    do {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true else {
            throw Failure("not-a-file", "The selected path must resolve to a regular file.")
        }
        guard values.isReadable != false else {
            throw Failure("file-unreadable", "The selected file is not readable.")
        }
        return url
    } catch let failure as Failure {
        throw failure
    } catch {
        throw Failure("file-unavailable", "The selected file is unavailable: \(error.localizedDescription)")
    }
}

private func application(_ url: URL) throws -> [String: Any] {
    let url = url.standardizedFileURL
    guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
          let executable = bundle.executableURL,
          FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw Failure("invalid-application", "The selected location is not an executable application bundle.")
    }
    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
    return [
        "id": bundle.bundleIdentifier as Any? ?? NSNull(),
        "name": name,
        "path": url.path,
        "inputModes": ["mounted-file"],
        "arguments": [String](),
    ]
}

private func applications(for file: URL) -> [String: Any] {
    let workspace = NSWorkspace.shared
    let defaultURL = workspace.urlForApplication(toOpen: file)
    var seen = Set<String>()
    var entries = workspace.urlsForApplications(toOpen: file).compactMap { url -> [String: Any]? in
        guard seen.insert(url.standardizedFileURL.path).inserted else { return nil }
        return try? application(url)
    }
    if let defaultURL, seen.insert(defaultURL.standardizedFileURL.path).inserted,
       let entry = try? application(defaultURL) {
        entries.append(entry)
    }
    entries.sort { lhs, rhs in
        (lhs["name"] as? String ?? "").localizedStandardCompare(rhs["name"] as? String ?? "") == .orderedAscending
    }
    return [
        "file": file.path,
        "defaultApplicationId": defaultURL.flatMap { Bundle(url: $0)?.bundleIdentifier } as Any? ?? NSNull(),
        "defaultApplication": defaultURL.flatMap { try? application($0) } as Any? ?? NSNull(),
        "applications": entries,
    ]
}

private func chooseApplication(for file: URL?) throws -> [String: Any] {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = NSOpenPanel()
    panel.title = "Choose Application for Farshore"
    panel.message = "Choose the application to open this file. Farshore does not change system file associations."
    panel.prompt = "Choose Application"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
    app.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else {
        return ["cancelled": true, "application": NSNull()]
    }
    var result: [String: Any] = ["cancelled": false, "application": try application(url)]
    if let file {
        result["compatibleWithFile"] = NSWorkspace.shared.urlsForApplications(toOpen: file)
            .contains { $0.standardizedFileURL == url.standardizedFileURL }
    }
    return result
}

private func openFile(_ file: URL, appID: String?, appPath: String?) throws -> [String: Any] {
    guard appID == nil || appPath == nil else {
        throw Failure("invalid-arguments", "Choose either --app or --app-path.", exitCode: 2)
    }
    let workspace = NSWorkspace.shared
    var selectedURL: URL?
    if let appID {
        guard !appID.isEmpty, let url = workspace.urlForApplication(withBundleIdentifier: appID) else {
            throw Failure("application-missing", "The selected application is no longer installed. Choose a replacement.")
        }
        selectedURL = url
    } else if let appPath {
        selectedURL = try absoluteURL(appPath, option: "--app-path")
    }
    if let selectedURL { _ = try application(selectedURL) }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    configuration.createsNewApplicationInstance = false
    configuration.allowsRunningApplicationSubstitution = false
    var completed = false
    var runningApplication: NSRunningApplication?
    var launchError: Error?
    let completion: (NSRunningApplication?, Error?) -> Void = { running, error in
        // NSWorkspace completes on a concurrent queue. Marshal the result back
        // to main so the run loop below and its state share one thread.
        DispatchQueue.main.async {
            runningApplication = running
            launchError = error
            completed = true
        }
    }
    if let selectedURL {
        workspace.open([file], withApplicationAt: selectedURL, configuration: configuration, completionHandler: completion)
    } else {
        workspace.open(file, configuration: configuration, completionHandler: completion)
    }
    // Callers must impose a subprocess timeout. On timeout do not automatically
    // retry: the OS may already have accepted the open request.
    while !completed { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    if let launchError {
        throw Failure("open-failed", "The application could not open this file: \(launchError.localizedDescription)")
    }
    guard let runningApplication else {
        throw Failure("open-failed", "The operating system did not acknowledge the open request.")
    }
    return [
        "file": file.path,
        "inputMode": "mounted-file",
        "selection": selectedURL == nil ? "system-default" : "application",
        "application": runningApplication.bundleURL.flatMap { try? application($0) } as Any? ?? NSNull(),
        "processIdentifier": Int(runningApplication.processIdentifier),
        "accepted": true,
        "completion": "application-accepted-open-request",
    ]
}

private func thumbnail(_ file: URL, outputPath: String?, sizeText: String?) throws -> [String: Any] {
    let size = sizeText.flatMap(Int.init) ?? (sizeText == nil ? 384 : 0)
    guard (64...1024).contains(size) else {
        throw Failure("invalid-size", "--size must be an integer between 64 and 1024.", exitCode: 2)
    }
    let output = try absoluteURL(outputPath, option: "--output")
    guard output.pathExtension.lowercased() == "png", output != file else {
        throw Failure("invalid-output", "--output must be a distinct PNG file path.", exitCode: 2)
    }
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw Failure("output-exists", "The thumbnail destination already exists.")
    }
    let values = try file.resourceValues(forKeys: [.fileSizeKey])
    guard let sourceBytes = values.fileSize, sourceBytes >= 0, sourceBytes <= maximumSourceBytes else {
        throw Failure("thumbnail-byte-budget", "Image thumbnails are limited to source files of 64 MiB.")
    }
    // ImageIO decodes in this helper process, outside the browser's UI process.
    // File data is obtained from the mounted/local path, never through a shell.
    // CGImageSource accepts ImageIO image formats. Do not additionally require
    // UTI conformance lookup: restricted helper environments may have no access
    // to LaunchServices' conformance database even for a valid public.png.
    guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetType(source) != nil else {
        throw Failure("unsupported-image", "This file is not a supported image. Open With remains available.")
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
          width > 0, height > 0, width <= maximumSourcePixels,
          height <= maximumSourcePixels / width else {
        throw Failure("thumbnail-pixel-budget", "The image dimensions are invalid or exceed the 80-million-pixel budget.")
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: size,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          image.width <= size, image.height <= size else {
        throw Failure("thumbnail-failed", "ImageIO could not generate a thumbnail within the output pixel budget.")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure("thumbnail-failed", "Could not create a PNG encoder.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("thumbnail-failed", "Could not encode the thumbnail.")
    }
    do {
        try (data as Data).write(to: output, options: .withoutOverwriting)
    } catch {
        throw Failure("output-unwritable", "Could not save the thumbnail: \(error.localizedDescription)")
    }
    return [
        "file": file.path, "output": output.path,
        "width": image.width, "height": image.height,
        "sourceWidth": width, "sourceHeight": height,
        "sourceBytes": sourceBytes, "outputBytes": data.length,
        "decoder": "ImageIO", "inputMode": "mounted-file",
    ]
}

// This capability URL is issued by Farshore's single-resource HTTP bridge.
// Never return it, or decoder errors containing it, through the JSON protocol.
private func protectedVideoURL(_ value: String?) throws -> URL {
    guard let value, value.utf8.count <= 512,
          let components = URLComponents(string: value),
          components.scheme == "http", components.host == "127.0.0.1",
          let port = components.port, (1024...65535).contains(port),
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          components.percentEncodedPath == components.path,
          components.path.range(of: "^/media/[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil,
          let url = components.url else {
        throw Failure("invalid-media-url", "Video thumbnails require a protected Farshore loopback resource.", exitCode: 2)
    }
    return url
}

private struct VideoThumbnailFrame {
    let image: CGImage
    let actualTime: CMTime
    let sourceWidth: Int
    let sourceHeight: Int
}

// AVFoundation's HTTP loader can request an entire large file, and does not
// accept a shorter successful Content-Range. Translate its incremental custom-
// scheme requests into bounded HTTP ranges instead. Cache at most eight 1-MiB
// blocks so repeated parser reads do not consume more bridge byte budget.
private final class VideoThumbnailResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.farshore.thumbnail.resource", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let source: URL
    let assetURL: URL
    private let blockBytes: Int64 = 1024 * 1024
    private let byteBudget: Int64 = 8 * 1024 * 1024
    private var reservedBytes: Int64 = 0
    private var requestCount = 0
    private var contentLength: Int64?
    private var contentType = UTType.mpeg4Movie.identifier
    private var blocks: [Int64: Data] = [:]
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var task: URLSessionDataTask?
    private var stopped = false
    private var waitingForRetry = false
    private var failure: Failure?
    private var receivedBytes = 0
    private var httpStatuses: [Int] = []
    private var busyRetries = 0
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(source: URL) {
        self.source = source
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)!
        components.scheme = "farshore-thumbnail"
        assetURL = components.url!
        super.init()
        queue.setSpecific(key: queueKey, value: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // A capability endpoint must never redirect.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped, loadingRequest.request.url == assetURL else { return false }
        pending.append(loadingRequest)
        pump()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
        pump()
    }

    func diagnostics() -> [String: Any] {
        if DispatchQueue.getSpecific(key: queueKey) == true { return diagnosticsOnQueue() }
        return queue.sync { diagnosticsOnQueue() }
    }

    func resourceFailure() -> Failure? {
        if DispatchQueue.getSpecific(key: queueKey) == true { return failure }
        return queue.sync { failure }
    }

    private func diagnosticsOnQueue() -> [String: Any] {
        ["requests": requestCount, "reservedBytes": reservedBytes,
         "receivedBytes": receivedBytes, "httpStatuses": httpStatuses,
         "busyRetries": busyRetries, "sourceBytes": contentLength as Any? ?? NSNull()]
    }

    func cancel() {
        queue.async { [self] in
            stopped = true
            task?.cancel()
            session.invalidateAndCancel()
            pending.removeAll()
            blocks.removeAll()
        }
    }

    private func fail(_ code: String = "thumbnail-resource-response", reason: String = "invalid-range") {
        if failure == nil {
            var details = diagnosticsOnQueue()
            details["stage"] = "resource"
            details["reason"] = reason
            failure = Failure(code, "The bounded video resource could not be read. Retry the preview.", details: details)
        }
        let error = NSError(domain: "FarshoreThumbnail", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The bounded video resource is unavailable."])
        for item in pending where !item.isCancelled && !item.isFinished {
            item.finishLoading(with: error)
        }
        pending.removeAll()
    }

    private func fetch(start: Int64?, count: Int64?, retry: Int = 0) {
        guard requestCount < 12 else { fail("thumbnail-request-budget", reason: "request-limit"); return }
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        if let start, let count {
            guard count > 0, count <= blockBytes, retry > 0 || reservedBytes + count <= byteBudget else {
                fail("thumbnail-byte-budget", reason: "byte-limit"); return
            }
            // A503 from our bridge is denied before SFTP starts. Retrying that
            // unserved range keeps its original reservation; every HTTP attempt
            // still counts toward the unchanged twelve-request lease limit.
            if retry == 0 { reservedBytes += count }
            request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        } else {
            request.httpMethod = "HEAD"
        }
        requestCount += 1
        // This is the trusted Farshore endpoint, whose server enforces the
        // response/aggregate byte budgets. Completion-handler URLSession tasks
        // buffer their response before this exact-body validation.
        task = session.dataTask(with: request) { [self] data, response, error in
            queue.async { [self] in
                task = nil
                guard !stopped else { return }
                guard error == nil, let response = response as? HTTPURLResponse else {
                    fail("thumbnail-resource-transport", reason: "transport-failed"); return
                }
                httpStatuses.append(response.statusCode)
                receivedBytes += data?.count ?? 0
                if response.statusCode == 503 && retry < 2 {
                    busyRetries += 1
                    waitingForRetry = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(100 * (retry + 1))) { [self] in
                        waitingForRetry = false
                        if !stopped { fetch(start: start, count: count, retry: retry + 1) }
                    }
                    return
                }
                let expectedStatus = start == nil ? 200 : 206
                guard response.statusCode == expectedStatus else {
                    fail(response.statusCode == 503 ? "thumbnail-resource-busy" : "thumbnail-resource-http",
                         reason: response.statusCode == 503 ? "busy" : "http-status")
                    return
                }
                if let start, let count {
                    guard response.statusCode == 206, let data, data.count == Int(count),
                          let length = contentLength,
                          response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(start + count - 1)/\(length)" else {
                        fail(); return
                    }
                    blocks[start] = data
                } else {
                    guard response.statusCode == 200,
                          let text = response.value(forHTTPHeaderField: "Content-Length"),
                          let length = Int64(text), length > 0 else { fail(); return }
                    contentLength = length
                    if let mime = response.mimeType, let type = UTType(mimeType: mime),
                       type.conforms(to: .audiovisualContent) {
                        contentType = type.identifier
                    }
                }
                pump()
            }
        }
        task?.resume()
    }

    private func pump() {
        guard !stopped, failure == nil, task == nil, !waitingForRetry else { return }
        pending.removeAll { $0.isCancelled || $0.isFinished }
        guard let item = pending.first else { return }
        guard let length = contentLength else { fetch(start: nil, count: nil); return }
        if let info = item.contentInformationRequest {
            if let allowed = info.allowedContentTypes, !allowed.isEmpty, !allowed.contains(contentType) {
                fail("unsupported-container", reason: "content-type-not-supported"); return
            }
            info.contentType = contentType
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = item.dataRequest else {
            item.finishLoading()
            pending.removeFirst()
            pump()
            return
        }
        let offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        let requestedEnd: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            requestedEnd = length
        } else {
            let (end, overflow) = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
            guard !overflow else { fail(); return }
            requestedEnd = min(length, end)
        }
        guard offset >= 0, requestedEnd >= 0 else { fail(); return }
        if offset >= requestedEnd {
            item.finishLoading()
            pending.removeFirst()
            pump()
            return
        }
        let blockStart = (offset / blockBytes) * blockBytes
        guard let block = blocks[blockStart] else {
            fetch(start: blockStart, count: min(blockBytes, length - blockStart))
            return
        }
        let localOffset = Int(offset - blockStart)
        let count = min(block.count - localOffset, Int(min(requestedEnd - offset, blockBytes)))
        guard count > 0 else { fail(); return }
        dataRequest.respond(with: block.subdata(in: localOffset..<(localOffset + count)))
        // Give the parser a chance to cancel a broad read after it has enough
        // metadata or frame data, instead of eagerly downloading the remainder.
        queue.async { [self] in pump() }
    }
}

// This process handles one thumbnail. A run loop on the calling thread keeps
// framework callbacks runnable; metadata loading and decoding stay asynchronous.
// AVAsset/AVAssetImageGenerator support asynchronous loading and cancellation;
// our mutable publication/cancellation state is protected by the lock.
private final class VideoThumbnailJob: @unchecked Sendable {
    private let lock = NSLock()
    private let asset: AVURLAsset
    private let loader: VideoThumbnailResourceLoader
    private var generator: AVAssetImageGenerator?
    private var cancelled = false
    private var completed: Result<VideoThumbnailFrame, Failure>?
    private var phase = "tracks"

    init(url: URL) {
        loader = VideoThumbnailResourceLoader(source: url)
        asset = AVURLAsset(url: loader.assetURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            // Reference movies must not cause implicit file or network reads
            // outside this single protected resource.
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    func result() -> Result<VideoThumbnailFrame, Failure>? {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func resourceFailure() -> Failure? { loader.resourceFailure() }

    func diagnostics() -> [String: Any] {
        var details = loader.diagnostics()
        lock.lock()
        details["stage"] = phase
        lock.unlock()
        return details
    }

    private func setPhase(_ value: String) {
        lock.lock()
        phase = value
        lock.unlock()
    }

    private func decoderFailure(_ reason: String, error: Error? = nil) -> Failure {
        if let resourceFailure = loader.resourceFailure() { return resourceFailure }
        var details = diagnostics()
        details["reason"] = reason
        var errors: [[String: Any]] = []
        var current = error as NSError?
        for _ in 0..<3 {
            guard let value = current else { break }
            let safeDomains = ["AVFoundationErrorDomain", "NSOSStatusErrorDomain", "NSURLErrorDomain", "FarshoreThumbnail"]
            errors.append(["domain": safeDomains.contains(value.domain) ? value.domain : "other", "code": value.code])
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if !errors.isEmpty { details["decoderErrors"] = errors }
        return Failure("unsupported-video", "The platform decoder could not generate this video thumbnail. Retry or use Open With.", details: details)
    }

    private func finish(_ result: Result<VideoThumbnailFrame, Failure>) {
        lock.lock()
        defer { lock.unlock() }
        if !cancelled && completed == nil { completed = result }
    }

    private func install(_ value: AVAssetImageGenerator) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        generator = value
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let value = generator
        lock.unlock()
        value?.cancelAllCGImageGeneration()
        asset.cancelLoading()
        loader.cancel()
    }

    func start(size: Int) async {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            setPhase("enabled-track")
            var enabledTrack: AVAssetTrack?
            // AVAssetImageGenerator selects the first ENABLED video track.
            // Check the same track before decoding rather than a disabled lead.
            for candidate in tracks {
                if try await candidate.load(.isEnabled) {
                    enabledTrack = candidate
                    break
                }
            }
            guard let track = enabledTrack else {
                finish(.failure(decoderFailure("no-enabled-video-track")))
                return
            }
            setPhase("dimensions")
            let dimensions = try await track.load(.naturalSize)
            guard dimensions.width.isFinite, dimensions.height.isFinite,
                  dimensions.width > 0, dimensions.height > 0,
                  dimensions.width <= Double(maximumSourcePixels),
                  dimensions.height <= Double(maximumSourcePixels) / dimensions.width else {
                finish(.failure(Failure("thumbnail-pixel-budget", "Video dimensions exceed the 80-million-pixel budget.")))
                return
            }
            let width = Int(ceil(dimensions.width))
            let height = Int(ceil(dimensions.height))
            setPhase("duration")
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            // A representative early frame, with keyframe tolerance, avoids
            // traversing a long file merely to create a browser thumbnail.
            let sampleSeconds = seconds.isFinite && seconds > 0 ? min(1, seconds * 0.1) : 0
            let value = AVAssetImageGenerator(asset: asset)
            value.appliesPreferredTrackTransform = true
            value.maximumSize = CGSize(width: size, height: size)
            value.requestedTimeToleranceBefore = .positiveInfinity
            value.requestedTimeToleranceAfter = .positiveInfinity
            guard install(value) else { return }
            setPhase("frame")
            value.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: sampleSeconds, preferredTimescale: 600))]) {
                [self] _, image, actualTime, status, error in
                guard status == .succeeded, let image,
                      image.width > 0, image.height > 0,
                      image.width <= size, image.height <= size else {
                    finish(.failure(decoderFailure("frame-unavailable", error: error)))
                    return
                }
                finish(.success(VideoThumbnailFrame(image: image, actualTime: actualTime,
                                                     sourceWidth: width, sourceHeight: height)))
            }
        } catch {
            // AVFoundation's NSError may embed the capability URL. Deliberately
            // expose only this constant message, including for HTTP failures.
            finish(.failure(decoderFailure("decoder-failed", error: error)))
        }
    }
}

private func videoThumbnail(urlText: String?, outputPath: String?, sizeText: String?, timeoutText: String?) throws -> [String: Any] {
    let url = try protectedVideoURL(urlText)
    let size = sizeText.flatMap(Int.init) ?? (sizeText == nil ? 384 : 0)
    guard (64...1024).contains(size) else {
        throw Failure("invalid-size", "--size must be an integer between 64 and 1024.", exitCode: 2)
    }
    let timeout = timeoutText.flatMap(Double.init) ?? (timeoutText == nil ? 10 : 0)
    guard timeout.isFinite, (1...10).contains(timeout) else {
        throw Failure("invalid-timeout", "--timeout must be between 1 and 10 seconds.", exitCode: 2)
    }
    let output = try absoluteURL(outputPath, option: "--output")
    guard output.pathExtension.lowercased() == "png" else {
        throw Failure("invalid-output", "--output must be a PNG file path.", exitCode: 2)
    }
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw Failure("output-exists", "The thumbnail destination already exists.")
    }
    let job = VideoThumbnailJob(url: url)
    let task = Task.detached(priority: .utility) { await job.start(size: size) }
    defer { task.cancel(); job.cancel() }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while job.result() == nil && job.resourceFailure() == nil && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard let result = job.result() else {
        if let failure = job.resourceFailure() { throw failure }
        throw Failure("thumbnail-timeout", "Video thumbnail generation exceeded its time budget.", details: job.diagnostics())
    }
    let frame = try result.get()
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure("thumbnail-failed", "Could not create a PNG encoder.")
    }
    CGImageDestinationAddImage(destination, frame.image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("thumbnail-failed", "Could not encode the thumbnail.")
    }
    do { try (data as Data).write(to: output, options: .withoutOverwriting) }
    catch { throw Failure("output-unwritable", "Could not save the video thumbnail.") }
    let actualSeconds = CMTimeGetSeconds(frame.actualTime)
    return [
        "output": output.path, "width": frame.image.width, "height": frame.image.height,
        "sourceWidth": frame.sourceWidth, "sourceHeight": frame.sourceHeight,
        "actualTimeSeconds": actualSeconds.isFinite ? actualSeconds : 0,
        "outputBytes": data.length, "decoder": "AVFoundation", "inputMode": "protected-loopback",
    ]
}

private func run() throws -> [String: Any] {
    let arguments = CommandLine.arguments.dropFirst()
    guard let command = arguments.first else {
        throw Failure("invalid-arguments", "A command is required. Run self-check for supported commands.", exitCode: 2)
    }
    switch command {
    case "self-check":
        _ = try parseOptions(arguments.dropFirst(), allowed: [])
        return [
            "platform": "macos", "helper": "farshore-native",
            "commands": ["self-check", "applications", "choose-application", "open", "thumbnail", "video-thumbnail"],
            "inputModes": ["mounted-file", "protected-loopback"],
            "thumbnail": ["decoder": "ImageIO", "imagesOnly": true, "maximumSourceBytes": maximumSourceBytes,
                          "maximumSourcePixels": maximumSourcePixels, "maximumOutputDimension": 1024],
            "videoThumbnail": ["decoder": "AVFoundation", "inputMode": "protected-loopback",
                               "maximumSourcePixels": maximumSourcePixels, "maximumOutputDimension": 1024,
                               "maximumReadBytes": 8 * 1024 * 1024, "readChunkBytes": 1024 * 1024,
                               "maximumRequests": 12,
                               "defaultTimeoutSeconds": 10, "maximumTimeoutSeconds": 10],
        ]
    case "applications":
        let options = try parseOptions(arguments.dropFirst(), allowed: ["--file"])
        return applications(for: try inputFile(options["--file"]))
    case "choose-application":
        let options = try parseOptions(arguments.dropFirst(), allowed: ["--file"])
        let file = try options["--file"].map { try inputFile($0) }
        return try chooseApplication(for: file)
    case "open":
        let options = try parseOptions(arguments.dropFirst(), allowed: ["--file", "--app", "--app-path"])
        return try openFile(inputFile(options["--file"]), appID: options["--app"], appPath: options["--app-path"])
    case "thumbnail":
        let options = try parseOptions(arguments.dropFirst(), allowed: ["--file", "--output", "--size"])
        return try thumbnail(inputFile(options["--file"]), outputPath: options["--output"], sizeText: options["--size"])
    case "video-thumbnail":
        // Platform decoder diagnostics can contain the private capability URL.
        // The helper's sole response for this command is its sanitized JSON.
        freopen("/dev/null", "w", stderr)
        let options = try parseOptions(arguments.dropFirst(), allowed: ["--url", "--output", "--size", "--timeout"])
        return try videoThumbnail(urlText: options["--url"], outputPath: options["--output"],
                                  sizeText: options["--size"], timeoutText: options["--timeout"])
    default:
        throw Failure("unknown-command", "Unknown command. Run self-check for supported commands.", exitCode: 2)
    }
}

do {
    let result = try run()
    emit(["version": protocolVersion, "ok": true, "result": result])
} catch let failure as Failure {
    var error: [String: Any] = ["code": failure.code, "message": failure.message]
    if let details = failure.details { error["details"] = details }
    emit(["version": protocolVersion, "ok": false, "error": error])
    exit(failure.exitCode)
} catch {
    emit(["version": protocolVersion, "ok": false, "error": ["code": "native-failure", "message": error.localizedDescription]])
    exit(1)
}
