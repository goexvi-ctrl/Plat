import AppKit
import PlatCore
import SwiftUI

struct SettingsView: View {
    @Bindable var prefs: Preferences
    var model: ScanModel

    var body: some View {
        TabView {
            ColorSettings(prefs: prefs, model: model)
                .tabItem { Label("Colors", systemImage: "paintpalette") }
            FontSettings(prefs: prefs)
                .tabItem { Label("Fonts", systemImage: "textformat") }
        }
        .frame(width: 560, height: 470)
    }
}

// MARK: - Colors

private struct ColorSettings: View {
    @Bindable var prefs: Preferences
    var model: ScanModel

    @State private var usage: [ExtensionUsage] = []
    @State private var newExtension = ""

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
                    fileTypes
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Reset Colors") { prefs.resetColors() }
                    .disabled(prefs.appearance.colors.isEmpty
                              && prefs.appearance.kindColors.isEmpty
                              && prefs.appearance.extensionColors.isEmpty)
                Spacer()
            }
            .padding(12)
        }
        .task { usage = model.isReady ? model.tree.extensionUsage(limit: 24) : [] }
    }

    // MARK: File types

    @ViewBuilder
    private var fileTypes: some View {
        Text("File types")
            .font(.headline)
        Text("Pin a colour to an extension.  Anything not pinned is coloured from "
             + "the palette below, picked by hashing its name -- which is why those "
             + "colours have no particular meaning on their own.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(prefs.appearance.extensionColors.keys.sorted(), id: \.self) { ext in
            HStack(spacing: 12) {
                ColorPicker("", selection: Binding(
                    get: { prefs.appearance.extensionColor(ext)?.swiftUI ?? .gray },
                    set: { prefs.appearance.setExtension(ext, to: ColorRGBA($0)) }),
                    supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44)
                Text(".\(ext)").font(.system(.body, design: .monospaced))
                Spacer()
                Button("Remove") { prefs.appearance.setExtension(ext, to: nil) }
                    .buttonStyle(.link)
            }
        }

        HStack(spacing: 8) {
            TextField("extension", text: $newExtension)
                .frame(width: 110)
                .onSubmit(addExtension)
            Button("Add", action: addExtension)
                .disabled(AppearanceSettings.normalizeExtension(newExtension).isEmpty)
            Spacer()
        }

        if !suggestions.isEmpty {
            Text("In this scan")
                .font(.subheadline)
                .padding(.top, 2)
            Text("The extensions using the most space here.  Click one to pin it at "
                 + "the colour it already has.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 6)],
                      alignment: .leading, spacing: 6) {
              ForEach(suggestions) { item in
                Button { pin(item.ext) } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(currentColor(for: item.ext))
                            .frame(width: 11, height: 11)
                        Text(".\(item.ext)").font(.system(size: 11, design: .monospaced))
                        Text(ByteFormat.string(item.bytes))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Pin a colour to .\(item.ext)")
              }
            }
        }

        Divider().padding(.vertical, 4)
        Text("File kinds")
            .font(.headline)
        Text("Every other file takes the colour of its kind.  macOS decides which "
             + "kind a file is from its type, so anything it recognises is covered "
             + "without listing extensions here.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(FileKind.allCases, id: \.self) { kind in
            HStack(spacing: 12) {
                ColorPicker("", selection: Binding(
                    get: { prefs.appearance.color(for: kind).swiftUI },
                    set: { prefs.appearance.set(kind, to: ColorRGBA($0)) }),
                    supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44)
                Text(kind.displayName)
                Spacer()
                if let examples = examples(for: kind) {
                    Text(examples)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if prefs.appearance.kindColors[kind.rawValue] != nil {
                    Button("Reset") { prefs.appearance.set(kind, to: nil) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var suggestions: [ExtensionUsage] {
        usage.filter { prefs.appearance.extensionColor($0.ext) == nil }
    }

    private func addExtension() {
        let key = AppearanceSettings.normalizeExtension(newExtension)
        guard !key.isEmpty else { return }
        pin(key)
        newExtension = ""
    }

    /// Pin at the colour the extension already shows, so pinning changes
    /// nothing until the colour is actually edited.
    private func pin(_ ext: String) {
        prefs.appearance.setExtension(ext, to: ColorRGBA(NSColor(currentColor(for: ext)).cgColor)
            ?? ColorRGBA(red: 0.5, green: 0.5, blue: 0.5))
    }

    private func currentColor(for ext: String) -> Color {
        prefs.appearance.effectiveColor(forExtension: ext).swiftUI
    }

    /// Extensions from the open scan that land in this kind, so each row says
    /// what it actually covers rather than leaving "Document" to the imagination.
    private func examples(for kind: FileKind) -> String? {
        let hits = usage.filter { FileKind.of(extension: $0.ext) == kind }
            .prefix(4).map { "." + $0.ext }
        return hits.isEmpty ? nil : hits.joined(separator: " ")
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
        case .freeSpace:  c = t.freeSpace
        case .notScanned: c = t.notScanned
        }
        return ColorRGBA(c) ?? ColorRGBA(red: 0, green: 0, blue: 0)
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
