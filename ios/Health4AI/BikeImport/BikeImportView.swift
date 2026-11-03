import SwiftUI

// "Bike on your network": opt-in import of indoor-cycling rides from a Peloton Pi head unit on the
// user's own Wi-Fi into Apple Health. Colour rule (design.md): semantic colour on symbols only.

struct BikeImportView: View {
    @StateObject private var model = BikeImportCoordinator.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var testing = false
    @State private var healthOpenFailed = false

    var body: some View {
        List {
            Section {
                Text("For a Peloton Pi or compatible bike on your Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            addressSection
            importSection

            if model.isEnabled {
                Section("Last import") {
                    resultRows
                    Button {
                        Task { await model.importNow() }
                    } label: {
                        Label(model.isRunning ? "Importing\u{2026}" : "Import now", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isRunning)
                }
            }
        }
        .navigationTitle("Bike on your network")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshStatus() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshStatus() } }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Address

    private var testDisabled: Bool { testing || model.urlText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var addressSection: some View {
        Section {
            if model.isEnabled {
                // Locked while on: a wrapping Text shows the whole address at any text size.
                Text(model.urlText)
                Text("Turn import off to change the address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Bike address", text: $model.urlText, prompt: Text("peloton-pi.local:8080"), axis: .vertical)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { model.validateAddress() }
                    .onChange(of: model.urlText) { _, text in
                        model.addressProblem = nil
                        // A vertical-axis field wraps; Return must still mean "done", never a line break in the address.
                        if text.contains("\n") {
                            model.urlText = text.replacingOccurrences(of: "\n", with: "")
                            model.validateAddress()
                        }
                    }
            }
            if let problem = model.addressProblem {
                Label { Text(problem) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.caption)
            }
            Button {
                testing = true
                Task { await model.testConnection(); testing = false }
            } label: {
                // Plain Label, no foregroundStyle (design.md rule 3). Disabled, the TITLE dims and the icon keeps
                // its tint: platform behaviour, accepted by the design gate.
                Label("Test connection", systemImage: "network")
            }
            .disabled(testDisabled)
            if let message = model.testMessage {
                Label { Text(message) } icon: {
                    Image(systemName: model.testFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.testFailed ? .red : .green)
                }
                .font(.caption)
            }
        } header: {
            Text("Bike address")
        } footer: {
            Text("health4ai talks to the bike directly over your Wi-Fi and saves rides only to Apple Health. If you sync Workouts, imported rides are included like any other workout.")
        }
    }

    // MARK: Import switch and permission state

    private var importSection: some View {
        Section {
            Toggle("Import rides into Apple Health", isOn: Binding(
                get: { model.isEnabled || model.isRequestingAccess },
                set: { on in Task { await model.setEnabled(on) } }
            ))
            .disabled(model.isRequestingAccess)
            if model.isRequestingAccess {
                Text("Asking Health\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.coreAccess.denied.isEmpty {
                // One message naming what is missing; the setup error would only repeat it.
                Label {
                    Text(BikeCopy.deniedMessage(missing: model.coreAccess.denied, isEnabled: model.isEnabled))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                Button {
                    openHealth()
                } label: {
                    Label("Open Health", systemImage: "heart.text.square")
                }
                if healthOpenFailed {
                    Text("Health could not be opened from here. Open it from your Home Screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = model.setupError {
                Label { Text(error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.caption)
            }
        } header: {
            Text("Import")
        } footer: {
            Text("Off by default. Turning it on asks Health for permission to save workouts, active energy, cycling distance, power and cadence. All five are required. Heart rate is asked for only when a ride has it. \(BikeCopy.heartRateCannotBeAddedLater) A ride you delete from Health is imported again on the next import.")
        }
    }

    private func openHealth() {
        healthOpenFailed = false
        guard let url = URL(string: "x-apple-health://") else { return }
        openURL(url) { accepted in if !accepted { healthOpenFailed = true } }
    }

    // MARK: Results

    private static func rideDate(_ d: Date) -> String { BikeCopy.rideDate(d) }

    @ViewBuilder private var resultRows: some View {
        if let r = model.lastResult {
            if r.error != nil {
                // Hidden while the permission message above is showing, so the same words appear once.
                // The row never goes silent: when the words are hidden, one short line stands in for them.
                Label { Text(BikeCopy.errorLine(r, denied: model.coreAccess.denied)) } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .font(.subheadline)
            } else {
                Label {
                    Text(r.imported == 0 ? "No new rides." : "Imported \(r.imported) ride\(r.imported == 1 ? "" : "s").")
                } icon: {
                    Image(systemName: r.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.isSuccess ? .green : .orange)
                }
                .font(.subheadline)
                if r.alreadyImported > 0 {
                    Text("\(r.alreadyImported) already in Health").font(.caption).foregroundStyle(.secondary)
                }
            }
            issueRow("Failed", r.failed, symbol: "xmark.circle.fill", tint: .red)
            issueRow("Not imported", r.skipped, symbol: "minus.circle.fill", tint: .secondary)
            issueRow("Not confirmed", r.unconfirmed, symbol: "questionmark.circle.fill", tint: .orange)
            issueRow("Note", r.notes, symbol: "info.circle.fill", tint: .secondary)
            Text(BikeCopy.rideDate(r.date)).font(.caption).foregroundStyle(.secondary)
        } else if !model.isRunning {
            Text("No import yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func issueRow(_ title: String, _ issues: [BikeIssue], symbol: String, tint: Color) -> some View {
        if let s = BikeIssueSummary(issues, format: Self.rideDate) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("\(title): \(s.count) ride\(s.count == 1 ? "" : "s")")
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .font(.subheadline)
                Text(s.reason).font(.caption)
                if let detail = s.detail {
                    // The dates are the rides with the reason above, not every ride in the row.
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if s.otherReasons > 0 {
                    Text("and \(s.otherReasons) other reason\(s.otherReasons == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        // Run-level lines are not about a ride: plain captions, no "N rides".
        ForEach(BikeIssueSummary.runLevel(issues), id: \.self) { line in
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { BikeImportView() }
}
