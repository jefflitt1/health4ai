import SwiftUI

// MARK: - SyncHistoryView

/// Reachable from Home. Reads `SyncHistoryStore` fresh `onAppear`, since entries are written
/// from background sync paths this view is never subscribed to.
struct SyncHistoryView: View {
    @State private var entries: [SyncHistoryEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No syncs recorded yet. Runs appear here as soon as one completes, including while the app is closed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    SyncHistoryRow(entry: entry)
                }
            }
        }
        .navigationTitle("Sync History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = SyncHistoryStore.shared.all() }
        // iPad: caps the reading width instead of a one-line row stretching edge to edge.
        // See SourcesView for why both `.scrollContentBackground(.hidden)` and the explicit
        // background are needed: capping the List's own frame otherwise leaves bare white
        // bands either side of it instead of matching gray.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct SyncHistoryRow: View {
    let entry: SyncHistoryEntry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // design.md colour rule: the semantic goes on the symbol, the words stay .primary.
    private var titleLabel: some View {
        Label {
            Text(entry.trigger.displayName)
                .foregroundStyle(.primary)
                // The trigger labels are now full plain-English sentences ("Automatic, app
                // closed", "You tapped Sync Now") rather than one or two words, so at large
                // but non-accessibility sizes the row's fixed width could still truncate a
                // title that would fit on two lines. `.fixedSize` lets the Text grow
                // vertically instead of clipping to `…`; verified at accessibilityXXXL.
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            statusIcon
        }
        .font(.subheadline.weight(.medium))
    }

    private var statusIcon: some View {
        Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(entry.success ? Color.green : Color.red)
            // Same words in both layouts, not the symbol's own name.
            .accessibilityLabel(entry.success ? "Succeeded" : "Failed")
    }

    /// Accessibility sizes: the icon on its own line above the title. Beside it, the icon took
    /// enough width that "Automatic, app closed" broke before its comma (Sasha, 2026-10-19).
    private var stackedTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusIcon
            Text(entry.trigger.displayName)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
    }

    private var relativeDate: some View {
        Text(entry.date, format: .relative(presentation: .named))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // An HStack squeezing the trigger label against the date column has almost no
            // width left for the label at accessibility sizes, and SwiftUI wraps that
            // remaining sliver character-by-character rather than word-by-word — the exact
            // shape of bug this app has already been bitten by with numeric text (see
			// HomeView.progressLines). Stacked instead, same as AdaptiveLabeledField.
            // From xxxLarge, not only the accessibility sizes: at xxxLarge the date column still
            // left "Automatic, app closed" so little room that it broke before the comma
            // (Sasha, 2026-10-19).
            if dynamicTypeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 2) {
                    if dynamicTypeSize.isAccessibilitySize { stackedTitle } else { titleLabel }
                    relativeDate
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    titleLabel
                    Spacer()
                    relativeDate
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            if entry.success {
                if entry.totalCount > 0 {
                    if entry.trigger == .importHistory {
                        // A history import's one "History import" key is bookkeeping for
                        // the summary count, not a metric name worth repeating back to the
                        // user in parentheses — every other row's "(names)" suffix exists
                        // to say WHICH of ~120 possible types moved, which this run answers
                        // in its own row already (its trigger IS "History import").
                        Text("\(entry.totalCount.formatted()) record\(entry.totalCount == 1 ? "" : "s") imported")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let lines = SheetsCountLines.lines(entry.counts) {
                        // A Sheets pass writes days, workouts and sleep records: unlike things,
                        // so each is its own line and they are never added up (design.md
                        // "Honest numbers"). One Text per line keeps each number whole.
                        ForEach(lines, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        let names = entry.counts.keys.sorted()
                        Text("\(entry.totalCount.formatted()) record\(entry.totalCount == 1 ? "" : "s") sent (\(names.joined(separator: ", ")))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Checked, nothing new")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = entry.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { SyncHistoryView() }
}
