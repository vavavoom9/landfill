import AppKit
import LandfillCore
import QuickLookThumbnailing

/// Renders icons at their decay stage. Same-type files share a bitmap; previews are capped.
final class IconRenderer {
    static let stages = 7

    /// One step a day: 0 is fresh, `stages` is the last day.
    static func stage(of item: LandfillItem) -> Int {
        min(stages, Int(item.decay * Double(stages)))
    }

    private var shared: [String: NSImage] = [:]
    private var previews: [String: (image: NSImage, path: String, used: UInt64)] = [:]
    private let previewLimit = 160
    private var tick: UInt64 = 0
    private var requested = Set<String>()
    private var inFlight = 0
    private let maxInFlight = 6
    var onUpdate: (() -> Void)?

    func image(for item: LandfillItem, points: CGFloat, scale: CGFloat) -> NSImage {
        let pixels = max(16, Int((points * scale).rounded()))
        let stage = Self.stage(of: item)
        let amount = Double(stage) / Double(Self.stages)
        let key = "\(item.url.path)|\(item.modifiedAt.timeIntervalSince1970)|\(pixels)|\(stage)"
        tick += 1
        if let hit = previews[key] {
            previews[key]?.used = tick
            return hit.image
        }

        let ext = item.url.pathExtension.lowercased()
        let isFolder = item.url.hasDirectoryPath
        if isFolder && !ext.isEmpty {
            // bundles carry their own icon
            let image = render(NSWorkspace.shared.icon(forFile: item.url.path), pixels: pixels, points: points,
                               amount: amount, seed: Self.seed(item.name))
            store(image, for: key, path: item.url.path)
            return image
        }
        if !isFolder {
            requestPreview(for: item, key: key, points: points, scale: scale, pixels: pixels, amount: amount)
        }
        let sharedKey = "\(isFolder ? "/" : ext)|\(pixels)|\(stage)"
        if let hit = shared[sharedKey] { return hit }
        if shared.count > 400 { shared.removeAll() }
        let image = render(NSWorkspace.shared.icon(forFile: item.url.path), pixels: pixels, points: points,
                           amount: amount, seed: Self.seed(ext))
        shared[sharedKey] = image
        return image
    }

    private func render(_ icon: NSImage, pixels: Int, points: CGFloat, amount: Double, seed: UInt64) -> NSImage {
        let base = Self.rasterize(pixels: pixels) { rect in icon.draw(in: rect) }
        return NSImage(cgImage: Self.decompose(base, amount: amount, seed: seed),
                       size: NSSize(width: points, height: points))
    }

    private func store(_ image: NSImage, for key: String, path: String) {
        previews = previews.filter { $0.value.path != path }
        if previews.count >= previewLimit, let oldest = previews.min(by: { $0.value.used < $1.value.used }) {
            previews.removeValue(forKey: oldest.key)
        }
        previews[key] = (image, path, tick)
    }

    func keepOnly(_ paths: Set<String>) {
        previews = previews.filter { paths.contains($0.value.path) }
    }

    private func requestPreview(for item: LandfillItem, key: String, points: CGFloat, scale: CGFloat,
                                pixels: Int, amount: Double) {
        // preview slots full: keep the type icon
        guard inFlight < maxInFlight, previews.count + inFlight < previewLimit, !requested.contains(key) else { return }
        if requested.count > 4000 { requested.removeAll() }
        requested.insert(key)
        inFlight += 1
        let path = item.url.path
        let seed = Self.seed(item.name)
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: points, height: points), scale: scale,
            representationTypes: .thumbnail)
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            var image: NSImage?
            if let cg = thumbnail?.cgImage {
                let fitted = Self.rasterize(pixels: pixels) { rect in
                    let size = CGSize(width: cg.width, height: cg.height)
                    let ratio = min(rect.width / size.width, rect.height / size.height)
                    let fit = CGSize(width: size.width * ratio, height: size.height * ratio)
                    NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(
                        x: rect.midX - fit.width / 2, y: rect.midY - fit.height / 2,
                        width: fit.width, height: fit.height))
                }
                image = NSImage(cgImage: Self.decompose(fitted, amount: amount, seed: seed),
                                size: NSSize(width: points, height: points))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight -= 1
                if let image { self.store(image, for: key, path: path) }
                // redraw on failure too, so waiting files get a slot
                self.onUpdate?()
            }
        }
    }

    // MARK: - Pixels

    private static func makeContext(_ pixels: Int) -> CGContext {
        CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                  bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func rasterize(pixels: Int, _ draw: (CGRect) -> Void) -> CGImage {
        let context = makeContext(pixels)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.current = previous
        return context.makeImage()!
    }

    private static func seed(_ name: String) -> UInt64 {
        name.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    private static func noise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        func corner(_ ix: Int, _ iy: Int) -> Double {
            var h = seed ^ (UInt64(bitPattern: Int64(ix)) &* 0x9E3779B97F4A7C15) ^ (UInt64(bitPattern: Int64(iy)) &* 0xC2B2AE3D27D4EB4F)
            h ^= h >> 31; h = h &* 0xD6E8FEB86659FD93; h ^= h >> 32
            return Double(h & 0xFFFF) / 65535
        }
        let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
        var fx = x - Double(ix), fy = y - Double(iy)
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
        let top = corner(ix, iy) + (corner(ix + 1, iy) - corner(ix, iy)) * fx
        let bottom = corner(ix, iy + 1) + (corner(ix + 1, iy + 1) - corner(ix, iy + 1)) * fx
        return top + (bottom - top) * fy
    }

    /// amount: 0 untouched, 1 about to go.
    private static func decompose(_ base: CGImage, amount: Double, seed: UInt64) -> CGImage {
        guard amount > 0 else { return base }
        let size = base.width
        let context = makeContext(size)
        context.draw(base, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return base }
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        let grey = amount * 0.75
        let fade = 1 - 0.2 * amount
        let reach = pow(amount, 1.3) * 0.42      // how far the decay has eaten in
        let soft = 0.03                          // width of the antialiased edge of a bite
        let rim = 0.09                           // width of the darkened band beside a bite
        let half = Double(size) / 2
        let coarse = 8.0 / Double(size), fine = 21.0 / Double(size)

        for y in 0..<size {
            let dy = abs(Double(y) - half) / half
            for x in 0..<size {
                let i = (y * size + x) * 4
                if pixels[i + 3] == 0 { continue }
                let dx = abs(Double(x) - half) / half
                let outward = min(1, max(dx, dy) / 0.74)
                let grain = 0.6 * noise(Double(x) * coarse, Double(y) * coarse, seed: seed)
                    + 0.4 * noise(Double(x) * fine, Double(y) * fine, seed: seed ^ 0xA5A5)
                let strength = grain * 0.5 + (1 - outward) * 0.5

                var keep = (strength - (reach - soft)) / (2 * soft)
                keep = min(1, max(0, keep))
                keep = keep * keep * (3 - 2 * keep)
                if keep == 0 {
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                    continue
                }
                let scorch = 1 - 0.6 * min(1, amount * 2) * max(0, 1 - (strength - reach) / rim)

                var r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                r += (luma - r) * grey; g += (luma - g) * grey; b += (luma - b) * grey
                let alpha = keep * fade
                pixels[i] = UInt8(r * scorch * alpha)
                pixels[i + 1] = UInt8(g * scorch * alpha)
                pixels[i + 2] = UInt8(b * scorch * alpha)
                pixels[i + 3] = UInt8(Double(pixels[i + 3]) * alpha)
            }
        }
        return context.makeImage() ?? base
    }
}
