import SwiftUI

// MARK: - SourcesView

/// "Your sources" — every device or app that has contributed HealthKit data, from
/// `SourcesTracker`. Reachable from Home.
struct SourcesView: View {
    @State private var sources: [(name: String, info: HealthSourceInfo)] = []

    var body: some View {
        List {
            Section {
                Text("health4ai syncs anything that writes to Apple Health, not just Apple Watch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if sources.isEmpty {
                Section {
                    Text("No sources seen yet. This fills in once your data has synced at least once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(sources, id: \.name) { entry in
                        SourceRow(name: entry.name, info: entry.info)
                    }
                } header: {
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                }
            }
        }
        .navigationTitle("Your Sources")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sources = SourcesTracker.shared.all() }
    }
}

private struct SourceRow: View {
    let name: String
    let info: HealthSourceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.weight(.medium))
            Text("\(info.sampleCount.formatted()) sample\(info.sampleCount == 1 ? "" : "s") · last seen \(info.lastSeen.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { SourcesView() }
}
