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
        } icon: {
            Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(entry.success ? Color.green : Color.red)
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
            if dynamicTypeSize >= .accessibility1 {
                VStack(alignment: .leading, spacing: 2) {
                    titleLabel
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
                    let names = entry.counts.keys.sorted()
                    Text("\(entry.totalCount.formatted()) record\(entry.totalCount == 1 ? "" : "s") sent (\(names.joined(separator: ", ")))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Checked — nothing new")
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
