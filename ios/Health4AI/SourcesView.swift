import SwiftUI

// MARK: - SourcesView

/// "Your sources" — every device or app that has contributed HealthKit data, from
/// `SourcesTracker`. Reachable from Home.
struct SourcesView: View {
    @State private var sources: [(name: String, info: HealthSourceInfo)] = []

    /// Apple's own first-party devices, checked by name against `HKSource.name` strings as
    /// Apple actually reports them ("Apple Watch", "iPhone", "AirPods Pro", …). Sorted last,
    /// so a third-party app or device — the thing this screen exists to prove health4ai
    /// notices — is not buried under Jeff's own Apple hardware.
    private static func isAppleDevice(_ name: String) -> Bool {
        let appleNames = ["apple watch", "iphone", "ipad", "airpods", "apple health"]
        let lowered = name.lowercased()
        return appleNames.contains { lowered.contains($0) }
    }

    private var sortedSources: [(name: String, info: HealthSourceInfo)] {
        sources.sorted { lhs, rhs in
            let lhsApple = Self.isAppleDevice(lhs.name)
            let rhsApple = Self.isAppleDevice(rhs.name)
            if lhsApple != rhsApple { return !lhsApple }
            return lhs.info.lastSeen > rhs.info.lastSeen
        }
    }

    var body: some View {
        List {
            if sources.isEmpty {
                Section {
                    Text("No sources seen yet. This fills in once your data has synced at least once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(sortedSources, id: \.name) { entry in
                        SourceRow(name: entry.name, info: entry.info)
                    }
                } header: {
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                } footer: {
                    Text("health4ai syncs anything that writes to Apple Health, not just Apple Watch.")
                }
            }
        }
        .navigationTitle("Your Sources")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sources = SourcesTracker.shared.all() }
        // iPad: a full-width List of short rows reads as an oversized empty page. Capped and
        // centered, same as Home and the other new 1.0.1 screens.
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
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
