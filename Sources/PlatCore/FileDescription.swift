import Foundation

/// What a file actually contains, according to `file(1)`.
///
/// An extension is a claim; magic numbers are evidence.  "PNG image data,
/// 1024 x 1024, 8-bit/color RGBA, non-interlaced" says considerably more than
/// "PNG image", and it is right about a `.txt` that is really a JPEG.
///
/// This shells out rather than reimplementing magic matching: `/usr/bin/file`
/// ships with macOS, reads only the head of the file, and is the tool whose
/// answers people already recognise.
public enum FileDescription {

    /// Longest reply worth keeping.  A universal binary lists every
    /// architecture it holds and can run to several hundred characters.
    static let limit = 400

    /// Blocking.  Call it off the main thread -- `file` is fast on a local disk
    /// but nothing stops the path being on a stalled network mount.
    public static func of(path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        // -b drops the echoed filename; -- stops a name beginning with a dash
        // from being read as an option.  Arguments go straight to execve as
        // argv, never through a shell, so a file called "; rm -rf ~" is just a
        // file with a strange name.
        process.arguments = ["-b", "--", path]

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return clean(String(decoding: data, as: UTF8.self))
    }

    /// Trim, collapse the line breaks `file` puts between architectures, and
    /// cap the length.  Split out so it can be tested without running anything.
    static func clean(_ raw: String) -> String? {
        let joined = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        let text = joined.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // "cannot open ..." is how file reports a path it could not read; that
        // is not a description of anything.
        guard !text.hasPrefix("cannot open") else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\u{2026}"
    }
}
