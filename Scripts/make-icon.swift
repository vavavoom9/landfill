// Draws the app icon and writes Resources/AppIcon.icns.
//   usage: swift Scripts/make-icon.swift      (run from the repository root)
import AppKit

func drawIcon(_ s: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext

    // Background tile.
    let tile = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let colors = [CGColor(red: 0.27, green: 0.33, blue: 0.24, alpha: 1),
                  CGColor(red: 0.10, green: 0.13, blue: 0.10, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // The zone outline.
    let zone = tile.insetBy(dx: s * 0.11, dy: s * 0.11)
    ctx.addPath(CGPath(roundedRect: zone, cornerWidth: s * 0.075, cornerHeight: s * 0.075, transform: nil))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.setLineWidth(s * 0.022)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [s * 0.055, s * 0.05])
    ctx.strokePath()

    // A document that is partly gone.
    ctx.saveGState()
    ctx.translateBy(x: s * 0.5, y: s * 0.5)
    ctx.rotate(by: 0.14)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let w = s * 0.25, h = s * 0.33, fold = s * 0.075
    let page = CGMutablePath()
    page.move(to: CGPoint(x: -w / 2, y: -h / 2))
    page.addLine(to: CGPoint(x: w / 2, y: -h / 2))
    page.addLine(to: CGPoint(x: w / 2, y: h / 2 - fold))
    page.addLine(to: CGPoint(x: w / 2 - fold, y: h / 2))
    page.addLine(to: CGPoint(x: -w / 2, y: h / 2))
    page.closeSubpath()
    ctx.addPath(page)
    ctx.setFillColor(CGColor(red: 0.93, green: 0.92, blue: 0.86, alpha: 1))
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.55, green: 0.56, blue: 0.5, alpha: 1))
    for row in 0..<3 {
        ctx.fill(CGRect(x: -w * 0.32, y: h * 0.12 - CGFloat(row) * h * 0.14, width: w * (row == 2 ? 0.4 : 0.64), height: h * 0.045))
    }
    // Bites out of the lower corner.
    ctx.setBlendMode(.destinationOut)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    let bites: [(CGFloat, CGFloat, CGFloat)] = [
        (0.46, -0.46, 0.20), (0.22, -0.52, 0.11), (0.52, -0.22, 0.10), (0.02, -0.50, 0.07),
        (0.30, -0.30, 0.055), (-0.20, -0.47, 0.045), (0.47, 0.0, 0.05), (0.12, -0.26, 0.03),
    ]
    for (x, y, r) in bites {
        ctx.fillEllipse(in: CGRect(x: x * w - r * w, y: y * h - r * w, width: 2 * r * w, height: 2 * r * w))
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try tool.run()
tool.waitUntilExit()
try? fm.removeItem(at: iconset)
print(tool.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
