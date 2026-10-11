import AppKit

/// The "Icon & widget style" setting from System Settings.
struct WidgetStyle: Equatable {
    enum Look { case regular, clear, tinted }

    static let themeKey = "AppleIconAppearanceTheme"
    static let tintKeys = ["AppleIconAppearanceCustomTintColor", "AppleIconAppearanceTintColor"]
    static var observedKeys: [String] { [themeKey] + tintKeys }

    var look = Look.regular
    /// nil follows the system's light or dark mode.
    var appearance: NSAppearance.Name?
    var tint: NSColor?

    static func current(_ defaults: UserDefaults = .standard) -> WidgetStyle {
        let theme = defaults.string(forKey: themeKey) ?? ""
        var style = WidgetStyle()
        if theme.hasPrefix("Clear") { style.look = .clear }
        if theme.hasPrefix("Tinted") { style.look = .tinted }
        if theme.hasSuffix("Dark") { style.appearance = .darkAqua }
        if theme.hasSuffix("Light") { style.appearance = .aqua }
        if style.look == .tinted {
            style.tint = tintKeys.lazy.compactMap { color(from: defaults.object(forKey: $0)) }.first
                ?? .controlAccentColor
        }
        return style
    }

    private static func color(from value: Any?) -> NSColor? {
        if let data = value as? Data {
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        }
        if let parts = value as? [NSNumber], parts.count >= 3 {
            return NSColor(srgbRed: parts[0].doubleValue, green: parts[1].doubleValue, blue: parts[2].doubleValue, alpha: 1)
        }
        guard let text = value as? String else { return nil }
        let numbers = text.split(whereSeparator: { " ,".contains($0) }).compactMap { Double($0) }
        if numbers.count >= 3 {
            return NSColor(srgbRed: numbers[0], green: numbers[1], blue: numbers[2], alpha: 1)
        }
        let named: [String: NSColor] = [
            "blue": .systemBlue, "purple": .systemPurple, "pink": .systemPink, "red": .systemRed,
            "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen, "graphite": .systemGray,
            "teal": .systemTeal, "mint": .systemMint, "indigo": .systemIndigo, "cyan": .systemCyan, "brown": .systemBrown,
        ]
        return named[text.lowercased()]
    }
}

class ZoneBackgroundView: NSView {
    static let cornerRadius: CGFloat = 28
    private var tile: NSView?
    private var style = WidgetStyle()

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Dark-style widgets are glass with a heavy dark tint, measured from real ones.
    private var tileTint: NSColor? {
        if let tint = style.tint { return tint.withAlphaComponent(0.55) }
        guard style.look == .regular, isDark else { return nil }
        return NSColor(srgbRed: 0.02, green: 0.03, blue: 0.06, alpha: 0.9)
    }

    func apply(_ style: WidgetStyle) {
        self.style = style
        appearance = style.appearance.flatMap { NSAppearance(named: $0) }
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    private func rebuild() {
        tile?.removeFromSuperview()
        let frame = bounds.insetBy(dx: WidgetGrid.tileInset, dy: WidgetGrid.tileInset)
        let view: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = Self.cornerRadius
            glass.style = style.look == .clear ? .clear : .regular
            glass.tintColor = tileTint
            view = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask()
            if let tint = style.tint {
                let wash = NSView(frame: effect.bounds)
                wash.autoresizingMask = [.width, .height]
                wash.wantsLayer = true
                wash.layer?.backgroundColor = tint.withAlphaComponent(0.3).cgColor
                effect.addSubview(wash)
            }
            view = effect
        }
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: nil)
        tile = view
    }

    private static func roundedMask() -> NSImage {
        let radius = cornerRadius
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
