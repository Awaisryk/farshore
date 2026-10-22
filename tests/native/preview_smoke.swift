// Concatenated after FarshorePreview.swift so this tests the production adapter.
import Foundation

@main
struct FarshorePreviewSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("PREVIEW_SMOKE_FAILED=\(message)\n", stderr); exit(1) }
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FARSHORE_STATE"]!)
        let cache = state.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<32 { for y in 0..<24 { image.setColor(.systemTeal, atX: x, y: y) } }
        let png = cache.appendingPathComponent("fixture.png")
        try image.representation(using: .png, properties: [:])!.write(to: png)
        let pdf = cache.appendingPathComponent("fixture.pdf")
        let pdfData = NSMutableData()
        var rectangle = CGRect(x: 0, y: 0, width: 320, height: 240)
        let context = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &rectangle, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 20, y: 20, width: 280, height: 200))
        context.endPDFPage()
        context.closePDF()
        try (pdfData as Data).write(to: pdf)
        let rtf = cache.appendingPathComponent("fixture.rtf")
        try Data("{\\rtf1\\ansi Farshore isolated Quick Look fixture.}".utf8).write(to: rtf)
        let word = cache.appendingPathComponent("fixture.docx")
        require(FileManager.default.fileExists(atPath: word.path), "office-fixture-missing")

        let outside = state.appendingPathComponent("outside.png")
        try Data([1]).write(to: outside)
        let linked = cache.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let html = cache.appendingPathComponent("fixture.html")
        try Data("<p>Not an admitted preview type.</p>".utf8).write(to: html)
        let large = cache.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath: large.path, contents: Data())
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FarshorePreviewFile.maximumBytes + 1))
        try handle.close()
        let invalid: [(String?, String)] = [
            (nil, "missing"), (outside.path, "outside"), (linked.path, "symlink"),
            (cache.path + "/../outside.png", "traversal"), (cache.path, "directory"),
            (large.path, "oversized"), (html.path, "html"), ("https://example.invalid/file.pdf", "url"),
        ]
        for (path, reason) in invalid {
            do { _ = try FarshorePreviewFile.validate(path); require(false, "accepted-\(reason)") }
            catch is FarshorePreviewFailure {}
        }

        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = host
        var views: [FarshorePreviewView] = []
        var closes = 0
        for file in [png, pdf, rtf, word] {
            let view = FarshorePreviewView(path: file.path)
            view.frame = host.bounds
            view.onClosed = { closes += 1 }
            host.addSubview(view)
            require(view.state["status"] as? String == "waiting", "factory-not-inert")
            require(view.subviews.isEmpty, "factory-started-reader")
            try view.open()
            try view.open() // Idempotence must not add duplicate readers.
            require(view.state["status"] as? String == "attached", "not-attached")
            require(view.subviews.count == 1, "duplicate-preview")
            views.append(view)
        }
        let until = Date().addingTimeInterval(2)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        require(!window.isVisible, "visible-window")
        for view in views {
            view.close()
            view.close()
            require(view.state["status"] as? String == "closed", "not-closed")
            require(view.subviews.isEmpty, "reader-still-attached")
            do { try view.open(); require(false, "reopened-closed-view") }
            catch is FarshorePreviewFailure {}
            view.removeFromSuperview()
        }
        require(closes == 4, "close-not-once")
        let canceled = FarshorePreviewView(path: png.path)
        canceled.close()
        do { try canceled.open(); require(false, "late-open-after-cancel") }
        catch is FarshorePreviewFailure {}
        require(canceled.subviews.isEmpty, "late-reader-after-cancel")

        func key(_ text: String, _ modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 44) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                             isARepeat: false, keyCode: code)!
        }
        require(isFarshorePreviewShortcut(key("/")), "slash-not-forwarded")
        require(isFarshorePreviewShortcut(key("l", .command, code: 37)), "cmd-l-not-forwarded")
        require(isFarshorePreviewShortcut(key("\u{1b}", [], code: 53)), "escape-not-forwarded")
        require(!isFarshorePreviewShortcut(key("\u{1b}", .shift, code: 53)), "shift-escape-forwarded")
        require(!isFarshorePreviewShortcut(key("?", .shift)), "question-forwarded")
        require(!isFarshorePreviewShortcut(key("/", .option)), "option-slash-forwarded")
        require(!isFarshorePreviewShortcut(key("j", [], code: 38)), "ordinary-key-forwarded")
        window.close()
        print("PREVIEW_SMOKE_OK=true FIXTURES=4 REJECTED=8 CLOSE_ACKS=4 FACTORY_INERT=true VISIBLE_WINDOW=false")
    }
}
