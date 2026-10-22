#!/usr/bin/env swift
import AppKit
import Foundation

// Original vector geometry shared by the SVG, sidebar mark and native icon.
// Run with `xcrun swift scripts/generate-brand-assets.swift` from the checkout.
// AppKit and iconutil are included with macOS; no design app or full Xcode needed.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("assets/branding", isDirectory: true)
let iconset = output.appendingPathComponent("Farshore.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let green = "#327f6c"
let white = "#faf9f6"
let waveRows: [CGFloat] = [96, 128, 160]
let waveSVG = waveRows.map { y -> String in
    let n = Int(y)
    return "M56 \(n) C68 \(n+8) 80 \(n+8) 92 \(n) C104 \(n-8) 116 \(n-8) 128 \(n) C140 \(n+8) 152 \(n+8) 164 \(n) C176 \(n-8) 188 \(n-8) 200 \(n)"
}.joined(separator: " ")
let markSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" role="img" aria-labelledby="title">
  <title id="title">Farshore</title>
  <rect width="256" height="256" rx="64" fill="\(green)"/>
  <path d="\(waveSVG)" fill="none" stroke="\(white)" stroke-width="14" stroke-linecap="round"/>
</svg>

"""
try Data(markSVG.utf8).write(to: output.appendingPathComponent("farshore-mark.svg"), options: .atomic)
try Data(markSVG.utf8).write(to: output.appendingPathComponent("favicon.svg"), options: .atomic)
let logoSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 256" role="img" aria-labelledby="title">
  <title id="title">Farshore</title>
  <rect width="256" height="256" rx="64" fill="\(green)"/>
  <path d="\(waveSVG)" fill="none" stroke="\(white)" stroke-width="14" stroke-linecap="round"/>
  <text x="304" y="174" fill="#253a37" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="148" font-weight="600" letter-spacing="-6">farshore</text>
</svg>

"""
try Data(logoSVG.utf8).write(to: output.appendingPathComponent("farshore-logo.svg"), options: .atomic)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r/255, g/255, b/255, alpha])!
}

func render(size: Int, native: Bool) throws -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "FarshoreBrand", code: 1)
    }
    context.scaleBy(x: CGFloat(size)/256, y: CGFloat(size)/256)
    context.translateBy(x: 0, y: 256)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    if native {
        // A traditional .icns tile for the CLT-only runner, with a transparent
        // outer margin. Layered Icon Composer variants are a future release item.
        context.translateBy(x: 16, y: 16)
        context.scaleBy(x: 0.875, y: 0.875)
    }
    let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 256, height: 256),
                      cornerWidth: 64, cornerHeight: 64, transform: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    if native {
        let gradient = CGGradient(colorsSpace: space,
                                  colors: [color(67,143,123), color(35,103,86)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 128, y: 0),
                                   end: CGPoint(x: 128, y: 256), options: [])
    } else {
        context.setFillColor(color(50,127,108))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    }
    context.restoreGState()
    context.setStrokeColor(color(250,249,246))
    context.setLineWidth(14)
    context.setLineCap(.round)
    for y in waveRows {
        context.move(to: CGPoint(x: 56, y: y))
        context.addCurve(to: CGPoint(x: 92, y: y), control1: CGPoint(x: 68, y: y+8), control2: CGPoint(x: 80, y: y+8))
        context.addCurve(to: CGPoint(x: 128, y: y), control1: CGPoint(x: 104, y: y-8), control2: CGPoint(x: 116, y: y-8))
        context.addCurve(to: CGPoint(x: 164, y: y), control1: CGPoint(x: 140, y: y+8), control2: CGPoint(x: 152, y: y+8))
        context.addCurve(to: CGPoint(x: 200, y: y), control1: CGPoint(x: 176, y: y-8), control2: CGPoint(x: 188, y: y-8))
        context.strokePath()
    }
    guard let cgImage = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FarshoreBrand", code: 2)
    }
    return png
}

// Sidebar/web assets fill their canvas; native icons retain the macOS margin.
try render(size: 256, native: false).write(to: output.appendingPathComponent("farshore-mark.png"), options: .atomic)
try render(size: 1024, native: true).write(to: output.appendingPathComponent("app-icon-1024.png"), options: .atomic)
try render(size: 180, native: false).write(to: output.appendingPathComponent("apple-touch-icon.png"), options: .atomic)
try render(size: 192, native: false).write(to: output.appendingPathComponent("icon-192.png"), options: .atomic)
try render(size: 512, native: false).write(to: output.appendingPathComponent("icon-512.png"), options: .atomic)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: points * scale, native: true).write(
            to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), options: .atomic)
    }
}
for size in [16, 32, 48] {
    try render(size: size, native: false).write(to: output.appendingPathComponent("favicon-\(size).png"), options: .atomic)
}

// PNG-compressed ICO entries preserve alpha and cover current browser sizes.
func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var number = value.littleEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
let faviconSizes = [16, 32, 48]
let pngs = try faviconSizes.map { try render(size: $0, native: false) }
var ico = Data([0, 0, 1, 0])
ico.append(littleEndian(UInt16(pngs.count)))
var offset = 6 + 16 * pngs.count
for (index, png) in pngs.enumerated() {
    let size = UInt8(faviconSizes[index])
    ico.append(contentsOf: [size, size, 0, 0])
    ico.append(littleEndian(UInt16(1)))
    ico.append(littleEndian(UInt16(32)))
    ico.append(littleEndian(UInt32(png.count)))
    ico.append(littleEndian(UInt32(offset)))
    offset += png.count
}
pngs.forEach { ico.append($0) }
try ico.write(to: output.appendingPathComponent("favicon.ico"), options: .atomic)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.appendingPathComponent("Farshore.icns").path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Generated SVG logo, sidebar mark, macOS icon and favicon set in assets/branding.")
