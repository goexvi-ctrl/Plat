import PlatCore
import SwiftUI

/// The confirmation shown before anything is moved to the Trash.
///
/// It exists to answer one question -- "will I regret this?" -- so the risk
/// verdict, not the file name, is the largest thing on it.  A plain "are you
/// sure?" teaches the user to click through without reading; a sheet that says
/// *why* an item is dangerous, and stays quiet about the ones that are not, is
/// worth reading.
struct DeleteSheet: View {
    let request: ScanModel.DeleteRequest
    var baseFontSize: Double = AppearanceSettings.defaultUIFontSize
    @Binding var askEveryTime: Bool
    var onCancel: () -> Void
    var onConfirm: () -> Void

    private var risk: DeleteRisk { request.assessment.risk }
    private var blocked: Bool { risk == .blocked }

    private var titleSize: CGFloat { CGFloat(baseFontSize + 2) }
    private var bodySize: CGFloat { CGFloat(baseFontSize - 1) }
    private var smallSize: CGFloat { CGFloat(baseFontSize - 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(request.path)
                    .font(.system(size: smallSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !request.assessment.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(request.assessment.notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\u{2022}")
                                Text(note).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: bodySize))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if !blocked { Divider(); sizeLine }
            }
            .padding(20)

            Divider()
            buttons
        }
        .frame(width: 460)
    }

    // MARK: Pieces

    /// A coloured strip naming the verdict, so the level registers before any
    /// of the prose is read.
    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: titleSize + 3, weight: .medium))
            VStack(alignment: .leading, spacing: 1) {
                Text(risk.label)
                    .font(.system(size: bodySize, weight: .semibold))
                Text(request.assessment.summary)
                    .font(.system(size: smallSize))
                    .opacity(0.85)
            }
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }

    private var sizeLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            if request.assessment.freesNothing {
                Label("Recovers no space", systemImage: "equal.circle")
                    .font(.system(size: bodySize, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Label("Recovers \(ByteFormat.string(request.assessment.reclaims))",
                      systemImage: "internaldrive")
                    .font(.system(size: bodySize, weight: .semibold))
            }
            if request.isDirectory {
                Text("\(ByteFormat.count(request.files)) files and "
                     + "\(ByteFormat.count(request.folders)) folders go with it.")
                    .font(.system(size: smallSize))
                    .foregroundStyle(.secondary)
            }
            Text("It goes to the Trash. Edit \u{203A} Undo puts it back, and it "
                 + "stays recoverable by hand until the Trash is emptied.")
                .font(.system(size: smallSize))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            // Offered only for the unremarkable cases: a destructive dialog is
            // no place to switch off destructive dialogs.
            if !blocked && risk <= .normal {
                Toggle("Ask every time", isOn: $askEveryTime)
                    .toggleStyle(.checkbox)
                    .font(.system(size: smallSize))
            }
            Spacer()
            if blocked {
                Button("OK", action: onCancel)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: onConfirm)
                    // Return confirms an ordinary delete but not a risky one:
                    // for those, nothing is bound, so a stray Return cancels
                    // instead of doing the damage.
                    .keyboardShortcut(risk >= .danger ? nil : .defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(risk >= .caution ? .red : .accentColor)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: String {
        if blocked { return "\u{201C}\(request.name)\u{201D} cannot be deleted" }
        return "Move \u{201C}\(request.name)\u{201D} to the Trash?"
    }

    private var symbol: String {
        switch risk {
        case .safe:    return "checkmark.circle.fill"
        case .normal:  return "trash.circle.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .danger:  return "exclamationmark.triangle.fill"
        case .blocked: return "nosign"
        }
    }

    private var tint: Color {
        switch risk {
        case .safe:    return .green
        case .normal:  return .accentColor
        case .caution: return .orange
        case .danger:  return .red
        case .blocked: return .secondary
        }
    }
}
