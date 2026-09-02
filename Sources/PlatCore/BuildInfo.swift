import Foundation

/// Where this build came from: the release version, the commit it was built
/// from, and whether the working tree had local edits at the time.
///
/// The values are stamped into the app's `Info.plist` by `make-app.sh` (see
/// `scripts/version-info.sh`), rather than generated into a source file, so
/// building never leaves a modified file behind in git.
public struct BuildInfo: Sendable, Equatable {
    public var version: String
    /// Short hash of the commit built from; empty outside a git checkout.
    public var commitHash: String
    /// Date of that commit, YYYY-MM-DD.  Disambiguates same-day commits
    /// together with the hash.
    public var commitDate: String
    /// "modified" when the tree had tracked edits at build time, else empty.
    public var treeState: String
    /// UTC timestamp, recorded only for builds from a modified tree.
    public var buildTime: String

    public init(version: String, commitHash: String = "", commitDate: String = "",
                treeState: String = "", buildTime: String = "") {
        self.version = version
        self.commitHash = commitHash
        self.commitDate = commitDate
        self.treeState = treeState
        self.buildTime = buildTime
    }

    public var isModified: Bool { treeState == "modified" }

    /// The version line, e.g.
    /// `Version 0.1.0 (2026-09-02) 8d1bd72 modified 2026-09-02T18:10:35Z`
    public var versionString: String {
        var s = "Version \(version)"
        if !commitDate.isEmpty { s += " (\(commitDate))" }
        if !commitHash.isEmpty { s += " \(commitHash)" }
        if !treeState.isEmpty {
            s += " \(treeState)"
            if !buildTime.isEmpty { s += " \(buildTime)" }
        }
        return s
    }

    /// The parenthesised half of the About panel's version line: the commit,
    /// marked when the build did not come from a clean tree.
    public var buildDetail: String {
        guard !commitHash.isEmpty else { return isModified ? "modified" : "" }
        return isModified ? "\(commitHash), modified" : commitHash
    }

    public init(bundle: Bundle) {
        func value(_ key: String) -> String {
            bundle.object(forInfoDictionaryKey: key) as? String ?? ""
        }
        let short = value("CFBundleShortVersionString")
        self.init(version: short.isEmpty ? "unknown" : short,
                  commitHash: value("PlatCommitHash"),
                  commitDate: value("PlatCommitDate"),
                  treeState: value("PlatTreeState"),
                  buildTime: value("PlatBuildTime"))
    }

    /// The running app's own build information.
    public static let current = BuildInfo(bundle: .main)
}
