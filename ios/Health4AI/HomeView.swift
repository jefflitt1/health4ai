import SwiftUI

struct HomeView: View {
    @EnvironmentObject var syncState: SyncState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    metricsGrid
                    backfillCard
                    actionsCard
                }
                .padding()
            }
            .navigationTitle("health4ai")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Status")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    statusLabel
                }
                Spacer()
                syncIcon
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(syncState.formattedLastSync)
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Next sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(syncState.formattedNextSync)
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var statusLabel: some View {
        if syncState.isSyncing {
            Label("Syncing", systemImage: "arrow.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
        } else if let error = syncState.syncError {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if syncState.isAuthenticated {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Label("Not connected", systemImage: "circle.slash")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var syncIcon: some View {
        if syncState.isSyncing {
            ProgressView()
                .scaleEffect(1.2)
        } else {
            Image(systemName: syncState.isAuthenticated ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.title)
                .foregroundStyle(syncState.isAuthenticated ? .pink : .secondary)
        }
    }

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(
                icon: "arrow.up.arrow.down.circle.fill",
                color: .blue,
                label: "Last batch",
                value: "\(syncState.lastSyncRecordCount)"
            )
            MetricTile(
                icon: "tray.full.fill",
                color: .purple,
                label: "Total synced",
                value: syncState.lifetimeSyncedRecords.formatted()
            )
        }
    }

    // MARK: - Backfill card

    private var backfillCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import Health History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if syncState.isBackfilling {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.85)
                        if syncState.backfillSyncedRecords == 0 {
                            Text("Scanning HealthKit…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(syncState.backfillSyncedRecords.formatted()) records synced")
                                    .font(.subheadline.weight(.medium))
                                if let date = syncState.backfillEarliestDate {
                                    Text("back to \(date.formatted(.dateTime.month().year()))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    Button(role: .destructive) {
                        BulkExportManager.shared.cancelBackfill()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else if syncState.backfillCompleted {
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Text("Import all historical health records from HealthKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Run Backfill") {
                    BulkExportManager.shared.startBackfill(syncState: syncState)
                }
                .disabled(!syncState.isAuthenticated)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions card

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                SyncEngine.shared.performForegroundSync()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28)
                    Text("Sync Now")
                    Spacer()
                    if syncState.isSyncing {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding()
            }
            .disabled(syncState.isSyncing || !syncState.isAuthenticated)
            Divider().padding(.leading, 44)
            Button {
                BulkExportManager.shared.startBackfill(syncState: syncState)
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 28)
                    Text(syncState.backfillCompleted ? "Re-run Backfill" : "Run Backfill")
                    Spacer()
                }
                .padding()
            }
            .disabled(!syncState.isAuthenticated || syncState.isBackfilling)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - MetricTile

private struct MetricTile: View {
    let icon: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Spacer()
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
