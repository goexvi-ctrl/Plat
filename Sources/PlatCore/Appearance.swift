import CoreGraphics
import Foundation

/// An sRGB colour that can be stored in preferences.
///
/// `CGColor` is neither `Codable` nor reliably comparable across colour spaces,
/// so preferences hold plain components and convert at the edges.
public struct ColorRGBA: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Converts into sRGB first: a colour taken from AppKit may be in any space,
    /// and reading `components` without converting yields nonsense for some.
    public init?(_ color: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]),
                  alpha: Double(c.count > 3 ? c[3] : 1))
    }

    /// Built explicitly in sRGB.  `CGColor(red:green:blue:alpha:)` makes a
    /// *generic* RGB colour, and reading that back as sRGB shifts the numbers --
    /// pure red returns as FF2600 -- so a colour chosen in the dialog would not
    /// be the colour drawn on the map.
    public var cgColor: CGColor {
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let c = CGColor(colorSpace: srgb,
                           components: [red, green, blue, alpha]) {
            return c
        }
        return CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Eight hex digits, RRGGBBAA.  Alpha matters here: most of the treemap's
    /// fills are translucent so the box beneath shows through.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let shift = hasAlpha ? 24 : 16
        func part(_ i: Int) -> Double { Double((v >> (shift - i * 8)) & 0xFF) / 255 }
        self.init(red: part(0), green: part(1), blue: part(2),
                  alpha: hasAlpha ? Double(v & 0xFF) / 255 : 1)
    }
}

/// The individually colourable parts of the map.
public enum ThemeColor: String, CaseIterable, Codable, Sendable {
    case background, container, collapsed, aggregate, linkMark, outline, label, highlight
    case freeSpace, notScanned

    public var displayName: String {
        switch self {
        case .background: return "Background"
        case .container:  return "Open folder"
        case .collapsed:  return "Unopened folder"
        case .aggregate:  return "Grouped small files"
        case .linkMark:   return "Hard-link flag"
        case .outline:    return "Box outline"
        case .label:      return "Label text"
        case .highlight:  return "Hover highlight"
        case .freeSpace:  return "Free space"
        case .notScanned: return "Not scanned"
        }
    }

    /// Shown beside each well, because "container" means nothing on its own.
    public var explanation: String {
        switch self {
        case .background: return "Behind everything"
        case .container:  return "A folder opened to show its contents"
        case .collapsed:  return "A folder with more inside than is drawn"
        case .aggregate:  return "The \"N smaller items\" block"
        case .linkMark:   return "Corner triangle on a hard-linked file"
        case .outline:    return "The line around every box"
        case .label:      return "Names and sizes drawn on boxes"
        case .highlight:  return "Outline of the box under the pointer"
        case .freeSpace:  return "Unused space on the volume"
        case .notScanned: return "Space in use that the scan could not see"
        }
    }
}

/// Everything the preferences dialog can change.
///
/// Colours are *overrides*: a slot that is absent falls back to the built-in
/// value, which follows the system light/dark appearance.  That way a person
/// can recolour one thing without losing the adaptive behaviour of the rest,
/// and "reset" is a deletion rather than a second set of hardcoded defaults.
public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var colors: [String: ColorRGBA]
    /// Colours pinned to particular file extensions, keyed lowercased and
    /// without the dot ("swift", "m").  Anything not listed falls back to the
    /// palette below, chosen by hashing the extension.
    public var extensionColors: [String: ColorRGBA]
    /// Per-kind overrides, keyed by `FileKind.rawValue`.  Absent means that
    /// kind keeps its built-in colour.
    public var kindColors: [String: ColorRGBA]
    public var mapFontName: String
    public var mapFontSize: Double
    /// Base size for the details panel; the other sizes there are derived.
    public var uiFontSize: Double

    public static let defaultMapFontName = "Helvetica"
    public static let defaultMapFontSize = 10.0
    public static let defaultUIFontSize = 14.0

    public init(colors: [String: ColorRGBA] = [:],
                extensionColors: [String: ColorRGBA] = [:],
                kindColors: [String: ColorRGBA] = [:],
                mapFontName: String = AppearanceSettings.defaultMapFontName,
                mapFontSize: Double = AppearanceSettings.defaultMapFontSize,
                uiFontSize: Double = AppearanceSettings.defaultUIFontSize) {
        self.colors = colors
        self.extensionColors = extensionColors
        self.kindColors = kindColors
        self.mapFontName = mapFontName
        self.mapFontSize = mapFontSize
        self.uiFontSize = uiFontSize
    }

    public var isDefault: Bool { self == AppearanceSettings() }

    public func color(_ slot: ThemeColor) -> ColorRGBA? { colors[slot.rawValue] }

    /// Normalised the way the renderer looks them up: lowercased, no leading
    /// dot, so a user typing ".M" and a file called `foo.m` agree.
    public static func normalizeExtension(_ raw: String) -> String {
        var e = raw.trimmingCharacters(in: .whitespaces).lowercased()
        while e.hasPrefix(".") { e.removeFirst() }
        return e
    }

    public mutating func setExtension(_ raw: String, to colour: ColorRGBA?) {
        let key = Self.normalizeExtension(raw)
        guard !key.isEmpty else { return }
        if let colour { extensionColors[key] = colour } else { extensionColors.removeValue(forKey: key) }
    }

    public func extensionColor(_ raw: String) -> ColorRGBA? {
        extensionColors[Self.normalizeExtension(raw)]
    }

    public mutating func set(_ slot: ThemeColor, to colour: ColorRGBA?) {
        if let colour { colors[slot.rawValue] = colour } else { colors.removeValue(forKey: slot.rawValue) }
    }

    /// A label strip has to clear the text plus a little air, or labels are
    /// clipped the moment the font is enlarged.
    public var labelHeight: CGFloat { CGFloat((mapFontSize * 1.3).rounded()) }

    /// Lay the overrides over a base theme, keeping every slot the user has not
    /// touched.
    public func apply(to base: RenderTheme) -> RenderTheme {
        var t = base
        for slot in ThemeColor.allCases {
            guard let c = color(slot)?.cgColor else { continue }
            switch slot {
            case .background: t.background = c
            case .container:  t.container = c
            case .collapsed:  t.collapsed = c
            case .aggregate:  t.aggregate = c
            case .linkMark:   t.linkMark = c
            case .outline:    t.outline = c
            case .label:      t.label = c
            case .highlight:  t.highlight = c
            case .freeSpace:  t.freeSpace = c
            case .notScanned: t.notScanned = c
            }
        }
        for (key, colour) in kindColors { t.kinds[key] = colour.cgColor }
        t.extensionColors = extensionColors.reduce(into: [:]) { $0[$1.key] = $1.value.cgColor }
        return t
    }

    public func color(for kind: FileKind) -> ColorRGBA {
        kindColors[kind.rawValue] ?? kind.defaultColor
    }

    public mutating func set(_ kind: FileKind, to colour: ColorRGBA?) {
        if let colour { kindColors[kind.rawValue] = colour }
        else { kindColors.removeValue(forKey: kind.rawValue) }
    }

    /// The colour a file with this extension gets right now: its pin if it has
    /// one, otherwise its kind's colour.  The settings dialog previews with
    /// this, so it cannot disagree with what the map draws.
    public func effectiveColor(forExtension raw: String) -> ColorRGBA {
        if let pinned = extensionColor(raw) { return pinned }
        return color(for: FileKind.of(extension: raw))
    }
}
