import Foundation

/// Human-readable byte counts.
///
/// This replaces the original `ntoa`, which built strings with `sprintf` into a
/// shared `static char[32]` (so two calls in one expression clobbered each
/// other) and whose fractional part was wrong at every scale: for 1500 bytes it
/// computed `(n / 10) % 10`, printing "1.50K" only by coincidence and "1.00K"
/// for 1090.
public enum ByteFormat {

    private static let units = ["KB", "MB", "GB", "TB", "PB", "EB"]

    /// Decimal units, matching what Finder reports.
    public static func string(_ bytes: Int64) -> String {
        if bytes < 1000 {
            return "\(bytes) B"
        }
        // `value` is already in units[0] (KB) after this division, so `unit`
        // indexes `units` directly.
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits: Int = value < 10 ? 2 : (value < 100 ? 1 : 0)
        return String(format: "%.\(digits)f %@", value, units[unit])
    }

    /// A compact form for drawing inside small boxes: no space, one decimal at most.
    public static func compact(_ bytes: Int64) -> String {
        if bytes < 1000 { return "\(bytes)B" }
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let symbol = String(units[unit].prefix(1))
        return value < 10 ? String(format: "%.1f%@", value, symbol)
                          : String(format: "%.0f%@", value, symbol)
    }

    public static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}
