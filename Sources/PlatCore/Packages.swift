import Foundation

/// What kind of bundle a directory is, when its name says it is one.
public enum PackageKind: String, Sendable, Equatable, Codable {
    /// A bundle whose contents are code: an application, a framework, a plugin.
    /// Removing any one file breaks the seal on the whole thing.
    case code
    /// A directory the Finder shows as a single document or library: a Pages
    /// file, a Photos library, a sparse bundle.
    case document

    public var noun: String {
        switch self {
        case .code:     return "bundle"
        case .document: return "document"
        }
    }
}

/// Directories that macOS presents as single objects.
///
/// This is one table with two readers, and it must stay that way: the treemap
/// draws a package as a single box, and the delete rules refuse to treat what
/// is inside one as an ordinary file.  Those two claims have to be about the
/// same set of directories or Plat contradicts itself -- offering to delete
/// something it drew as an indivisible object.
///
/// The obvious implementation would be `UTType(filenameExtension:)` and a test
/// for conformance to `com.apple.package`.  It does not work.  Probed against
/// the extensions below, almost all of them resolve to *dynamic* types
/// (`dyn.ah62d4rv4ge80q6xbrzw1s55wrq` for `framework`) because an extension is
/// only registered when some installed application claims it, and even `app`
/// resolves to `com.apple.application-file` rather than the bundle type -- so
/// not one of them reports conforming to `.package`.  `NSWorkspace` can answer
/// correctly but only per path, with I/O, which is no use in a layout pass.  An
/// explicit table costs nothing, needs no filesystem, and is right.
public enum Packages {

    /// Bundles whose contents are code.
    static let code: Set<String> = [
        "app", "framework", "bundle", "kext", "plugin", "appex", "xpc",
        "qlgenerator", "prefpane", "mdimporter", "component", "saver",
        "service", "systemextension", "dext", "driver", "wdgt", "vst", "vst3",
        "audiounit", "pluginkit",
    ]

    /// Bundles the Finder shows as one document or one library.
    static let document: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "aplibrary",
        "imovielibrary", "theater", "fcpbundle", "logicx", "band", "pages",
        "numbers", "key", "rtfd", "sparsebundle", "scptd", "abbu", "download",
        "migrationreport", "oo3", "graffle",
    ]

    /// Classify by extension.  The caller must already know the item is a
    /// directory: a `.pages` file exported flat is a file, not a package.
    public static func kind(ofExtension ext: String) -> PackageKind? {
        let e = ext.lowercased()
        if code.contains(e) { return .code }
        if document.contains(e) { return .document }
        return nil
    }

    /// Classify by name, for a path component known to be a directory.
    public static func kind(ofName name: String) -> PackageKind? {
        kind(ofExtension: (name as NSString).pathExtension)
    }
}
