import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A broad category for a file, in the style of Finder's "Kind" column.
///
/// The mapping is not a hand-written table of extensions: macOS already knows,
/// through Uniform Type Identifiers.  An extension resolves to a `UTType` and a
/// kind is simply the first supertype it conforms to, so anything the system
/// recognises is classified without this file having to list it.
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case application, archive, document, executable, image
    case movie, music, pdf, presentation, text, other

    public var displayName: String {
        switch self {
        case .application:  return "Application"
        case .archive:      return "Archive"
        case .document:     return "Document"
        case .executable:   return "Executable"
        case .image:        return "Image"
        case .movie:        return "Movie"
        case .music:        return "Music"
        case .pdf:          return "PDF"
        case .presentation: return "Presentation"
        case .text:         return "Text"
        case .other:        return "Other"
        }
    }

    /// Order matters, and it is not arbitrary.  Many types conform to several
    /// supertypes at once, so the first match wins and the sequence encodes the
    /// intent:
    ///
    ///  * Application before Archive, since an .app is a bundle.
    ///  * PDF before Document, since a PDF is composite content too.
    ///  * Executable includes `public.script`, and comes before Text.  An
    ///    interpreted program *is* the file you run, so .py, .sh and .js belong
    ///    with .o and .dylib rather than with prose.  Source that has to be
    ///    compiled -- .swift, .m, .c -- conforms to neither and stays Text,
    ///    which is right: there the binary is the program, not the source.
    private static let ladder: [(FileKind, [UTType])] = [
        (.application,  [.application]),
        (.pdf,          [.pdf]),
        (.image,        [.image]),
        (.movie,        [.movie, .video]),
        (.music,        [.audio]),
        (.archive,      [.archive]),
        (.presentation, [.presentation]),
        (.executable,   [.script, .executable, .unixExecutable]),
        (.text,         [.text]),
        (.document,     [.compositeContent, .spreadsheet]),
    ]

    /// Resolving a UTType is not free and a scan holds many files of few
    /// extensions, so answers are memoised.
    private static let cache = KindCache()

    /// Extensions where the system's answer is wrong on a developer's machine.
    ///
    /// Deliberately tiny.  The point of using Uniform Type Identifiers is not
    /// to maintain a table, so this holds only cases where the system is
    /// actively misleading rather than merely unhelpful -- an unrecognised
    /// extension lands in Other, which is honest, and can be pinned.
    ///
    /// TypeScript is the one that bites: `.ts` resolves to an MPEG-2 transport
    /// stream and `.mts` to AVCHD video, so a source tree reports hundreds of
    /// megabytes of "Movie".  The whole family is corrected together, since
    /// fixing `.ts` while `.tsx` stayed elsewhere would be its own confusion.
    /// TypeScript is compiled rather than run, so it belongs with .swift and
    /// .c in Text.
    private static let corrections: [String: FileKind] = [
        "ts": .text, "tsx": .text, "mts": .text, "cts": .text,
    ]

    public static func of(extension raw: String) -> FileKind {
        let key = AppearanceSettings.normalizeExtension(raw)
        guard !key.isEmpty else { return .other }
        if let corrected = corrections[key] { return corrected }
        if let hit = cache.get(key) { return hit }
        let kind = classify(key)
        cache.set(key, kind)
        return kind
    }

    private static func classify(_ ext: String) -> FileKind {
        guard let type = UTType(filenameExtension: ext) else { return .other }
        for (kind, supertypes) in ladder
        where supertypes.contains(where: { type.conforms(to: $0) }) {
            return kind
        }
        return .other
    }

    /// Distinct enough to tell apart at a glance in a dense map.
    public var defaultColor: ColorRGBA {
        switch self {
        case .application:  return ColorRGBA(hex: "8E6FC6FF")!
        case .archive:      return ColorRGBA(hex: "B08356FF")!
        case .document:     return ColorRGBA(hex: "5B8DD6FF")!
        case .executable:   return ColorRGBA(hex: "5A6472FF")!
        case .image:        return ColorRGBA(hex: "5FB36BFF")!
        case .movie:        return ColorRGBA(hex: "D2685FFF")!
        case .music:        return ColorRGBA(hex: "44A9AEFF")!
        case .pdf:          return ColorRGBA(hex: "C4506AFF")!
        case .presentation: return ColorRGBA(hex: "E0A24AFF")!
        case .text:         return ColorRGBA(hex: "7FA8C9FF")!
        case .other:        return ColorRGBA(hex: "9AA0A6FF")!
        }
    }
}

/// Small thread-safe memo.  The renderer runs on the main thread, but the
/// scanner's helpers may not, and a data race here would be miserable to find.
private final class KindCache: @unchecked Sendable {
    private var storage: [String: FileKind] = [:]
    private let lock = NSLock()

    func get(_ key: String) -> FileKind? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: String, _ value: FileKind) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}
