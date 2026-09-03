import Foundation

/// How much damage deleting one file or folder is likely to do.
///
/// Plat deletes by moving to the Trash, so this is deliberately not a scale of
/// how much would be *lost* -- almost anything in the Trash can be put back.
/// What it grades is whether the delete will silently fail, whether something
/// running will break, and whether the deletion escapes this Mac.  Those are
/// the three ways a disk cleanup turns into an afternoon of confusion.
public enum DeleteRisk: Int, Sendable, Comparable, CaseIterable, Codable {
    /// Regenerated on demand.  Deleting it costs time, not data.
    case safe
    /// An ordinary file.  It goes to the Trash and Put Back works.
    case normal
    /// Nothing breaks, but something is genuinely gone or has to be
    /// reinstalled or downloaded again.
    case caution
    /// Likely to break software that is installed or running, or the deletion
    /// reaches past this Mac to other devices.
    case danger
    /// The system will refuse the delete.
    case blocked

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe:    return "Safe to delete"
        case .normal:  return "Goes to the Trash"
        case .caution: return "Check before deleting"
        case .danger:  return "Deleting this is risky"
        case .blocked: return "Cannot be deleted"
        }
    }

    /// Whether Plat should insist on a confirmation even when the user has
    /// turned confirmations off.  The preference governs routine deletes; it
    /// does not buy a way to quietly break the system.
    public var alwaysConfirm: Bool { self >= .danger }
}

/// A verdict on one item, with the reasons that produced it.
public struct DeleteAssessment: Sendable, Equatable {
    public var risk: DeleteRisk = .normal
    /// One line naming what this thing is: "Cache data", "Inside an
    /// application bundle".
    public var summary: String = "File"
    /// Supporting detail, most important first.  Shown as a list.
    public var notes: [String] = []
    /// Best estimate of the blocks the volume actually gets back.
    public var reclaims: Int64 = 0
    /// Deleting frees nothing at all: another name holds the same blocks, or
    /// the bytes are not on this disk to begin with.
    public var freesNothing: Bool = false

    public init() {}

    mutating func raise(to level: DeleteRisk) { risk = max(risk, level) }
}

public enum DeleteSafety {

    // MARK: Entry points

    /// Assess a node of a scanned tree.  `runningApplicationPaths` comes from
    /// the app layer (`NSWorkspace.runningApplications`); PlatCore stays free
    /// of AppKit so this stays testable without a running window server.
    public static func assess(tree: FileTree, node: Int,
                              home: String = NSHomeDirectory(),
                              runningApplicationPaths: [String] = []) -> DeleteAssessment {
        guard node >= 0, node < tree.nodes.count else { return DeleteAssessment() }
        let entry = tree.nodes[node]
        guard !entry.isSynthetic else {
            var a = DeleteAssessment()
            a.risk = .blocked
            a.summary = "Not a file"
            a.notes = ["This block stands for capacity on the volume, not for "
                       + "anything on disk, so there is nothing to delete."]
            return a
        }

        let path = tree.path(of: node)
        var a = assess(path: path, isDirectory: entry.isDirectory,
                       home: home, runningApplicationPaths: runningApplicationPaths)

        // What the volume actually gets back.  A name that shares its blocks
        // with other names returns nothing until the last one goes.
        if tree.isHardLinked(node) {
            a.freesNothing = true
            a.reclaims = 0
            a.notes.append("\(entry.linkCount) names point at these blocks, so "
                           + "deleting this one frees no space at all.")
        } else {
            a.reclaims = entry.allocatedShared
        }

        if entry.isDirectory {
            let shared = sharedBytesBelow(tree: tree, node: node)
            if shared > 0 {
                a.notes.append("Some files below this folder are hard-linked "
                               + "elsewhere, so the space recovered may be less "
                               + "than \(ByteFormat.string(a.reclaims)).")
            }
        }
        return a
    }

    /// Assess a path on its own, without a scan.  Split out so the rules can be
    /// tested directly against paths that need not exist.
    public static func assess(path: String, isDirectory: Bool,
                              home: String = NSHomeDirectory(),
                              runningApplicationPaths: [String] = []) -> DeleteAssessment {
        var a = DeleteAssessment()

        // 1.  Filesystem flags first: they decide whether the delete can
        //     happen at all, and no path rule can overrule them.
        if let verdict = flagCheck(path) { return verdict }

        // 2.  Deletion needs write permission on the containing directory --
        //     not on the file, which is the usual mistake.
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && access(parent, W_OK) != 0 {
            a.risk = .blocked
            a.summary = "You do not have permission"
            a.notes = ["Removing an item needs write permission on the folder "
                       + "that contains it, and \(parent) is not writable by "
                       + "you."]
            return a
        }

        // 3.  Path rules, first match wins.
        classify(path: path, isDirectory: isDirectory, home: home, into: &a)

        // 4.  A running application is a fact about right now, and it upgrades
        //     whatever the path rules concluded.
        if let app = runningApplicationPaths.first(where: { isAtOrUnder(path: path, root: $0) }) {
            a.raise(to: .danger)
            let name = (app as NSString).lastPathComponent
            a.notes.insert("\(name) is running right now. Deleting part of a "
                           + "running application usually crashes it, and it may "
                           + "fail to launch afterwards.", at: 0)
        }
        return a
    }

    // MARK: Filesystem flags

    /// `SF_DATALESS` is not surfaced in Swift's Darwin overlay.
    private static let flagDataless: UInt32 = 0x4000_0000

    private static func flagCheck(_ path: String) -> DeleteAssessment? {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            var a = DeleteAssessment()
            a.risk = .blocked
            a.summary = "No longer on disk"
            a.notes = ["The scan found this item, but it is not there now."]
            return a
        }
        let flags = st.st_flags

        if flags & UInt32(bitPattern: SF_RESTRICTED) != 0 {
            var a = DeleteAssessment()
            a.risk = .blocked
            a.summary = "Protected by System Integrity Protection"
            a.notes = ["macOS refuses to remove this even for an administrator, "
                       + "and even for root. Nothing you can do in Plat will "
                       + "delete it."]
            return a
        }
        if flags & UInt32(bitPattern: SF_IMMUTABLE) != 0 {
            var a = DeleteAssessment()
            a.risk = .blocked
            a.summary = "Locked by the system"
            a.notes = ["The system immutable flag is set. Only a restart in "
                       + "single-user mode can clear it."]
            return a
        }
        if flags & UInt32(bitPattern: UF_IMMUTABLE) != 0 {
            var a = DeleteAssessment()
            a.risk = .blocked
            a.summary = "Locked"
            a.notes = ["This item is locked. Uncheck Locked in the Finder's Get "
                       + "Info window to delete it."]
            return a
        }
        if flags & flagDataless != 0 {
            var a = DeleteAssessment()
            a.risk = .danger
            a.summary = "Stored in the cloud, not on this Mac"
            a.notes = ["The contents have been evicted to iCloud, so deleting "
                       + "frees no space here \u{2014} but it does remove the file "
                       + "from every device signed in to your account."]
            a.freesNothing = true
            return a
        }
        return nil
    }

    // MARK: Path rules
    //
    // Ordered, first match wins, exactly like the UTI ladder in FileKind.  The
    // order is load-bearing: an Electron application ships a `node_modules`
    // folder inside its own bundle, so "inside a package" has to be tested
    // before "looks rebuildable" or Plat would call that one safe.

    private static func classify(path: String, isDirectory: Bool, home: String,
                                 into a: inout DeleteAssessment) {
        let components = path.split(separator: "/").map(String.init)
        let last = components.last ?? ""

        // -- Inside a package -------------------------------------------------
        // Everything above the final component: being *in* a package is the
        // dangerous case.  Deleting the package itself is judged further down.
        for enclosing in components.dropLast() {
            let ext = (enclosing as NSString).pathExtension.lowercased()
            if Packages.code.contains(ext) {
                a.risk = .danger
                a.summary = "Inside \(enclosing)"
                a.notes = ["This file is part of an application bundle. Removing "
                           + "any piece of one invalidates its code signature, "
                           + "and macOS will usually then refuse to launch it \u{2014} "
                           + "with an error that does not mention the missing "
                           + "file. Delete the whole \(enclosing) instead."]
                return
            }
            if Packages.document.contains(ext) {
                a.risk = .danger
                a.summary = "Inside \(enclosing)"
                a.notes = ["\(enclosing) looks like a single document or library "
                           + "in the Finder but is really a folder. Deleting "
                           + "pieces of it from underneath corrupts it; the "
                           + "owning application will not know what happened."]
                return
            }
        }

        // -- System ownership -------------------------------------------------
        for prefix in systemRoots where isAtOrUnder(path: path, root: prefix) {
            a.risk = .danger
            a.summary = "System file"
            a.notes = ["\(prefix) belongs to macOS. Removing anything under it "
                       + "can leave the system unable to boot or update."]
            return
        }

        // -- Reaches beyond this Mac -----------------------------------------
        if isAtOrUnder(path: path, root: home + "/Library/Mobile Documents") {
            a.risk = .danger
            a.summary = "iCloud Drive"
            a.notes = ["Deleting this removes it from iCloud and therefore from "
                       + "every other device signed in to the same account. The "
                       + "Trash on this Mac will not bring it back on the "
                       + "others."]
            return
        }

        // -- Irreplaceable local data ----------------------------------------
        for (prefix, what) in irreplaceable(home: home) where isAtOrUnder(path: path, root: prefix) {
            a.risk = .danger
            a.summary = what
            a.notes = ["There is usually no second copy of this. Make sure a "
                       + "backup exists before you delete it."]
            return
        }
        if last == ".git" || components.contains(".git") {
            a.risk = .danger
            a.summary = "Git repository data"
            a.notes = ["This holds a project's entire history, including commits "
                       + "that were never pushed anywhere."]
            return
        }

        // -- Breaks installed software ---------------------------------------
        for prefix in launchPaths(home: home) where isAtOrUnder(path: path, root: prefix) {
            a.risk = .danger
            a.summary = "Startup item"
            a.notes = ["Items here start background software at login or boot. "
                       + "Removing one stops whatever depends on it, often "
                       + "silently."]
            return
        }
        for prefix in packageManagerRoots where isAtOrUnder(path: path, root: prefix) {
            a.risk = .danger
            a.summary = "Installed by a package manager"
            a.notes = ["\(prefix) holds software installed outside the App "
                       + "Store. Deleting parts of it leaves commands that fail "
                       + "with confusing errors rather than disappearing."]
            return
        }

        // -- Safely rebuildable ----------------------------------------------
        for (prefix, what) in rebuildableRoots(home: home) where isAtOrUnder(path: path, root: prefix) {
            a.risk = .safe
            a.summary = what
            a.notes = ["This is regenerated automatically when it is next "
                       + "needed. Deleting it may make the next launch or build "
                       + "slower, and nothing else."]
            return
        }
        if isDirectory, rebuildableFolders.contains(last) {
            a.risk = .safe
            a.summary = "Build output"
            a.notes = ["A \(last) folder is produced by a build tool and can be "
                       + "recreated by running the build again."]
            return
        }
        if isAtOrUnder(path: path, root: home + "/.Trash") {
            a.risk = .safe
            a.summary = "Already in the Trash"
            a.notes = ["Emptying the Trash is the only way to get this space "
                       + "back."]
            return
        }

        // -- Costly but recoverable ------------------------------------------
        let ownExtension = (last as NSString).pathExtension.lowercased()
        if Packages.code.contains(ownExtension) {
            a.risk = .caution
            a.summary = ownExtension == "app" ? "Application" : "Application component"
            a.notes = ["Deleting the whole bundle is the correct way to remove "
                       + "an application, but its settings and data elsewhere in "
                       + "your Library are left behind, and you will need the "
                       + "installer to get it back."]
            return
        }
        if Packages.document.contains(ownExtension) {
            a.risk = .caution
            a.summary = "Document library"
            a.notes = ["This is one document or library in its entirety."]
            return
        }
        for (prefix, what) in appDataRoots(home: home) where isAtOrUnder(path: path, root: prefix) {
            a.risk = .caution
            a.summary = what
            a.notes = ["An application keeps its settings or its saved data "
                       + "here. Deleting it does not break the application, but "
                       + "it will come back as though newly installed."]
            return
        }

        // -- Ordinary --------------------------------------------------------
        a.risk = .normal
        a.summary = isDirectory ? "Folder" : "File"
        a.notes = []
    }

    /// The path rules on their own, so tests can exercise them against paths
    /// that need not exist.  `assess` runs the filesystem checks first and
    /// would reject an invented path before ever reaching these.
    static func classifyForTests(path: String, isDirectory: Bool, home: String,
                                 into a: inout DeleteAssessment) {
        classify(path: path, isDirectory: isDirectory, home: home, into: &a)
    }

    // MARK: Tables

    static let systemRoots = [
        "/System", "/bin", "/sbin", "/usr/bin", "/usr/lib", "/usr/libexec",
        "/usr/sbin", "/usr/share", "/private/var/db", "/Library/Apple",
        "/private/etc", "/cores", "/dev",
    ]

    static let packageManagerRoots = [
        "/opt/homebrew", "/usr/local", "/opt/local", "/opt/X11", "/Library/Frameworks",
    ]

    static let rebuildableFolders: Set<String> = [
        "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", "DerivedData", ".gradle", ".next", ".parcel-cache",
        ".turbo", ".swiftpm", ".build",
    ]

    static func launchPaths(home: String) -> [String] {
        ["/Library/LaunchDaemons", "/Library/LaunchAgents",
         "/System/Library/LaunchDaemons", "/System/Library/LaunchAgents",
         home + "/Library/LaunchAgents"]
    }

    static func irreplaceable(home: String) -> [(String, String)] {
        [(home + "/Library/Keychains",     "Keychain"),
         (home + "/Library/Mail",          "Mail"),
         (home + "/Library/Messages",      "Messages history"),
         (home + "/Library/Calendars",     "Calendars"),
         (home + "/Library/Group Containers", "Shared application data"),
         ("/Library/Keychains",            "System keychain"),
         (home + "/Library/Application Support/AddressBook", "Contacts"),
         (home + "/Library/Application Support/MobileSync",  "iPhone backups"),
         ("/Volumes/.timemachine",         "Time Machine backup"),
         ("/private/var/db/Backups.backupdb", "Time Machine backup")]
    }

    static func rebuildableRoots(home: String) -> [(String, String)] {
        [(home + "/Library/Caches",                        "Cache data"),
         ("/Library/Caches",                               "Cache data"),
         (home + "/Library/Logs",                          "Log files"),
         ("/private/var/log",                              "Log files"),
         (home + "/Library/Developer/Xcode/DerivedData",   "Xcode build data"),
         (home + "/Library/Developer/CoreSimulator/Caches", "Simulator cache"),
         (home + "/Library/Developer/Xcode/iOS DeviceSupport", "Xcode device symbols"),
         (home + "/.cache",                                "Cache data"),
         (home + "/.npm/_cacache",                         "npm cache"),
         (home + "/Library/Application Support/CrashReporter", "Crash reports"),
         ("/private/var/folders",                          "Temporary system data")]
    }

    static func appDataRoots(home: String) -> [(String, String)] {
        [(home + "/Library/Preferences",         "Application settings"),
         (home + "/Library/Containers",          "Sandboxed application data"),
         (home + "/Library/Application Support", "Application data"),
         ("/Applications",                       "Installed application"),
         (home + "/Applications",                "Installed application"),
         (home + "/Library/Developer/CoreSimulator/Devices", "Simulator device")]
    }

    // MARK: Helpers

    /// True when `path` is `root` itself or lies beneath it.  Compares whole
    /// components, so "/usr/binary" does not count as being under "/usr/bin".
    static func isAtOrUnder(path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Total blocks below a folder that are held by more than one name, and so
    /// may survive the delete.
    private static func sharedBytesBelow(tree: FileTree, node: Int) -> Int64 {
        var total: Int64 = 0
        var stack = [node]
        while let i = stack.popLast() {
            let n = tree.nodes[i]
            if !n.isDirectory && n.linkCount > 1 { total += n.allocatedSize }
            if n.childCount > 0 {
                let start = Int(n.childStart)
                stack.append(contentsOf: start ..< (start + Int(n.childCount)))
            }
        }
        return total
    }
}
