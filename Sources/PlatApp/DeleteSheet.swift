import AppKit
import PlatCore
import SwiftUI

/// The confirmation shown before anything is moved to the Trash.
///
/// One key decides: **Y** deletes, anything else closes the box.  Nothing is
/// bound to Return, so no reflex keystroke can destroy anything -- the only way
/// through is a letter nobody presses by accident.
///
/// The box stays small when the delete is ordinary.  A confirmation that always
/// prints five paragraphs teaches people to dismiss it unread, which costs more
/// than it saves; the risk assessment only takes up room when it has something
/// to say.
struct DeleteSheet: View {
    let request: ScanModel.DeleteRequest
    var baseFontSize: Double = AppearanceSettings.defaultUIFontSize
    var onCancel: () -> Void
    var onConfirm: () -> Void

    /// Held for as long as the sheet is up.  A local monitor rather than
    /// `.onKeyPress`, because it does not depend on which control inside the
    /// sheet happens to hold focus -- and in a dialog whose whole contract is
    /// "one key decides", a key reaching the wrong view is the one failure that
    /// must not happen.
    @State private var keys: Any?

    private var risk: DeleteRisk { request.assessment.risk }
    private var blocked: Bool { risk == .blocked }
    /// Reasons are worth the space only when something is actually at stake.
    private var showsReasons: Bool { risk >= .caution && !request.assessment.notes.isEmpty }

    private var titleSize: CGFloat { CGFloat(baseFontSize + 1) }
    private var bodySize: CGFloat { CGFloat(baseFontSize - 1) }
    private var smallSize: CGFloat { CGFloat(baseFontSize - 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if showsReasons { reasons }
            if !blocked { sizeLine }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: watchKeys)
        .onDisappear(perform: releaseKeys)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: titleSize + 12, weight: .regular))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: smallSize))
                    .foregroundStyle(risk >= .caution ? AnyShapeStyle(tint)
                                                      : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var reasons: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(request.assessment.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 7) {
                    Text("\u{2022}")
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sizeLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            if request.assessment.freesNothing {
                Text("Frees no space, even after emptying the Trash")
                    .font(.system(size: bodySize, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Text("Frees \(ByteFormat.string(request.assessment.reclaims)) "
                     + "when you empty the Trash"
                     + (request.isDirectory
                        ? ", with \(ByteFormat.count(request.files)) files and "
                          + "\(ByteFormat.count(request.folders)) folders"
                        : ""))
                    .font(.system(size: bodySize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Until then it still occupies the disk, in the Trash. "
                 + "Edit \u{203A} Undo puts it back.")
                .font(.system(size: smallSize))
                .foregroundStyle(.tertiary)
        }
    }

    /// The instruction is the point of the box, so it is the last thing read
    /// and it sits beside the buttons rather than buried above them.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // On its own line rather than squeezed beside the buttons: it is
            // the sentence the box exists to deliver, and it must not wrap.
            Text(instruction)
                .font(.system(size: bodySize, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
            Spacer(minLength: 8)
            if blocked {
                Button("Close", action: onCancel)
            } else {
                Button("Cancel", action: onCancel)
                Button("Delete", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(risk >= .caution ? .red : .accentColor)
            }
            }
        }
        // Deliberately no default action anywhere: Y is the only key that
        // deletes, and Return closes the box like everything else.
        .buttonStyle(.automatic)
    }

    // MARK: One key decides

    private func watchKeys() {
        releaseKeys()
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Command shortcuts are the system's, not this dialog's -- and one
            // of them opens Settings, whose window must keep its own
            // keystrokes.  Only what is typed into the sheet is ours.
            guard !event.modifierFlags.contains(.command),
                  event.window?.isSheet == true else { return event }
            MainActor.assumeIsolated {
                let typed = event.charactersIgnoringModifiers?.lowercased()
                if typed == "y" && !blocked { onConfirm() } else { onCancel() }
            }
            return nil          // nothing else in the sheet sees this key
        }
    }

    private func releaseKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    // MARK: Words

    private var title: String {
        blocked ? "\u{201C}\(request.name)\u{201D} cannot be deleted"
                : "Move \u{201C}\(request.name)\u{201D} to the Trash?"
    }

    /// The path when there is nothing to warn about, and the warning when there
    /// is: one line either way.  The blocked title already says it cannot be
    /// deleted, so that line gives only the reason.
    private var subtitle: String {
        switch risk {
        case .normal:  return request.path
        case .blocked: return request.assessment.summary
        default:       return "\(risk.label) \u{2014} \(request.assessment.summary)"
        }
    }

    private var instruction: String {
        blocked ? "Press any key to close."
                : "Press \u{201C}Y\u{201D} to delete, anything else to cancel."
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
