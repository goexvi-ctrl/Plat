import AppKit
import PlatCore
import SwiftUI

/// User-chosen colours and fonts, persisted as JSON in UserDefaults.
///
/// One blob rather than a key per setting: the shape changes as slots are added
/// or dropped, and a single decode with a fallback to defaults is easier to keep
/// correct than a dozen individually-migrated keys.
@Observable
@MainActor
final class Preferences {
    private static let key = "Appearance"

    var appearance: AppearanceSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            appearance = decoded
        } else {
            appearance = AppearanceSettings()
        }
    }

    private func save() {
        if appearance.isDefault {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(appearance) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func resetAll() { appearance = AppearanceSettings() }

    func resetColors() {
        appearance.colors = [:]
        appearance.kindColors = [:]
        appearance.extensionColors = [:]
    }

    func resetFonts() {
        appearance.mapFontName = AppearanceSettings.defaultMapFontName
        appearance.mapFontSize = AppearanceSettings.defaultMapFontSize
        appearance.uiFontSize = AppearanceSettings.defaultUIFontSize
    }

}

extension ColorRGBA {
    var swiftUI: Color { Color(cgColor) }

    init(_ color: Color) {
        self = ColorRGBA(NSColor(color).cgColor) ?? ColorRGBA(red: 0, green: 0, blue: 0)
    }
}
