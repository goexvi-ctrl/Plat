import AppKit
import PlatCore
import SwiftUI

struct SettingsView: View {
    @Bindable var prefs: Preferences

    var body: some View {
        TabView {
            ColorSettings(prefs: prefs)
                .tabItem { Label("Colors", systemImage: "paintpalette") }
            FontSettings(prefs: prefs)
                .tabItem { Label("Fonts", systemImage: "textformat") }
        }
        .frame(width: 520, height: 430)
    }
}

// MARK: - Colors

private struct ColorSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A colour you have not set follows the system light or dark "
                         + "appearance.  Resetting one puts it back under that control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ThemeColor.allCases, id: \.self) { slot in
                        row(slot)
                    }

                    Divider().padding(.vertical, 4)

                    Text("File boxes")
                        .font(.headline)
                    Text("Each file is coloured by its extension, so files of one kind "
                         + "read as a group.  These are the ten colours it picks from.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    leafGrid
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Reset Colors") { prefs.resetColors() }
                    .disabled(prefs.appearance.colors.isEmpty && prefs.appearance.leaves == nil)
                Spacer()
            }
            .padding(12)
        }
    }

    private func row(_ slot: ThemeColor) -> some View {
        HStack(spacing: 12) {
            ColorPicker("", selection: binding(slot), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.displayName)
                Text(slot.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if prefs.appearance.color(slot) != nil {
                Button("Reset") { prefs.appearance.set(slot, to: nil) }
                    .buttonStyle(.link)
            } else {
                Text("system")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A slot with no override shows the built-in light-appearance colour, so
    /// the well opens on something sensible rather than on transparent black.
    private func binding(_ slot: ThemeColor) -> Binding<Color> {
        Binding(
            get: {
                if let c = prefs.appearance.color(slot) { return c.swiftUI }
                return builtIn(slot).swiftUI
            },
            set: { prefs.appearance.set(slot, to: ColorRGBA($0)) })
    }

    private func builtIn(_ slot: ThemeColor) -> ColorRGBA {
        let t = RenderTheme.standard
        let c: CGColor
        switch slot {
        case .background: c = t.background
        case .container:  c = t.container
        case .collapsed:  c = t.collapsed
        case .aggregate:  c = t.aggregate
        case .linkMark:   c = t.linkMark
        case .outline:    c = t.outline
        case .label:      c = t.label
        case .highlight:  c = t.highlight
        }
        return ColorRGBA(c) ?? ColorRGBA(red: 0, green: 0, blue: 0)
    }

    private var leafGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                  spacing: 8) {
            ForEach(Array(prefs.leafPalette.enumerated()), id: \.offset) { index, colour in
                ColorPicker("", selection: Binding(
                    get: { colour.swiftUI },
                    set: { prefs.setLeaf(index, to: ColorRGBA($0)) }),
                    supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }
}

// MARK: - Fonts

private struct FontSettings: View {
    @Bindable var prefs: Preferences

    /// Families only, and sorted: the full face list runs to thousands and is
    /// useless in a picker.
    private var families: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Family", selection: $prefs.appearance.mapFontName) {
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        Slider(value: $prefs.appearance.mapFontSize, in: 6 ... 24, step: 1)
                        Text("\(Int(prefs.appearance.mapFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                    Text("Labels drawn inside the boxes.  A larger font needs a taller "
                         + "label strip, so fewer boxes are big enough to subdivide and "
                         + "the map gets coarser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    preview
                } header: {
                    Text("Map labels")
                }

                Section {
                    HStack {
                        Slider(value: $prefs.appearance.uiFontSize, in: 10 ... 22, step: 1)
                        Text("\(Int(prefs.appearance.uiFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                    Text("The figures in the details panel.  The name and the smaller "
                         + "text scale with it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Details panel")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Reset Fonts") { prefs.resetFonts() }
                Spacer()
            }
            .padding(12)
        }
    }

    private var preview: some View {
        HStack(spacing: 6) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Documents  4.21 GB")
                .font(.custom(prefs.appearance.mapFontName,
                              size: prefs.appearance.mapFontSize))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.12)))
        }
    }
}
