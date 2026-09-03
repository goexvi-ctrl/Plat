import Foundation

/// Moving files to the Trash, and taking them back out again.
///
/// Plat never calls `unlink`.  Everything goes through the Trash, so a mistake
/// costs a click rather than a restore from backup.
///
/// `FileManager.trashItem` rather than `NSWorkspace.recycle`: recycle hands the
/// work to the Finder and reports where things landed only sometimes -- probed
/// here, it trashed the file and returned an empty dictionary -- and without
/// that URL there is nothing to undo.  `trashItem` is synchronous, always names
/// the destination, and needs no Finder, which also makes it testable.
public enum Trash {

    public enum Failure: LocalizedError, Equatable {
        case refused(String)
        case notInTrash

        public var errorDescription: String? {
            switch self {
            case .refused(let why): return why
            case .notInTrash:       return "The item is no longer in the Trash."
            }
        }
    }

    /// Move one item to the Trash, reporting where it landed so it can be put
    /// back.
    @discardableResult
    public static func recycle(_ url: URL) throws -> URL? {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return landed as URL?
    }

    /// Put an item back where it came from.
    ///
    /// The Finder's own Put Back is driven by metadata Plat does not write, so
    /// this is a plain move -- with the checks a plain move needs.
    public static func putBack(from trashed: URL, to original: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashed.path) else { throw Failure.notInTrash }
        // Never overwrite: something may have taken the name back in the
        // meantime, and silently clobbering it would be a far worse bug than
        // refusing to undo.
        guard !fm.fileExists(atPath: original.path) else {
            throw Failure.refused("Something else is now at \(original.path).")
        }
        let parent = original.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else {
            throw Failure.refused("The folder \(parent.path) no longer exists.")
        }
        try fm.moveItem(at: trashed, to: original)
    }
}
