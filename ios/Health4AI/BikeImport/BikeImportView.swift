import SwiftUI

// "Bike on your network": opt-in import of indoor-cycling rides from a Peloton Pi head unit on the
// user's own Wi-Fi into Apple Health. Colour rule (design.md): semantic colour on symbols only.

struct BikeImportView: View {
    @StateObject private var model = BikeImportCoordinator.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var testing = false

    var body: some View {
        List {
            Section {
                TextField("http://peloton-pi.local:8080", text: $model.urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(model.isEnabled)
                if let problem = model.urlError {
                    Label { Text(problem) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .font(.caption)
                }
                Button {
                    testing = true
                    Task { await model.testConnection(); testing = false }
                } label: {
                    Label("Test connection", systemImage: "network")
                }
                .tint(.accentColor)
                .disabled(testing || model.urlError != nil || model.urlText.isEmpty)
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
                Text("Only .local names and private network addresses are accepted. health4ai talks to the bike directly over your Wi-Fi; nothing is sent to health4ai or anywhere else.")
            }

            Section {
                Toggle("Import rides into Apple Health", isOn: Binding(
                    get: { model.isEnabled },
                    set: { on in Task { await model.setEnabled(on) } }
                ))
                if let error = model.setupError {
                    Label { Text(error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .font(.caption)
                }
                if model.writeStatus == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .tint(.accentColor)
                    Text("Health write access is off. Open the Health app, then Sharing > Apps > health4ai, and turn on Workouts and the cycling types. Then switch this on again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Off by default. Turning it on asks Health for permission to save workouts, active energy, cycling distance, power and cadence. Heart rate is asked for only if a ride has it. A ride you delete from Health is imported again on the next import.")
            }

            if model.isEnabled {
                Section("Last import") {
                    resultRows
                    Button {
                        Task { await model.importNow() }
                    } label: {
                        Label(model.isRunning ? "Importing..." : "Import now", systemImage: "arrow.down.circle")
                    }
                    .tint(.accentColor)
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

    @ViewBuilder private var resultRows: some View {
        if let r = model.lastResult {
            if let error = r.error {
                Label { Text(error) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
                    .font(.subheadline)
            } else {
                Label {
                    Text(r.imported == 0 ? "No new rides." : "Imported \(r.imported) ride\(r.imported == 1 ? "" : "s").")
                } icon: {
                    Image(systemName: r.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.failed.isEmpty ? .green : .orange)
                }
                .font(.subheadline)
                if r.alreadyImported > 0 {
                    Text("\(r.alreadyImported) already in Health").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(r.failed, id: \.self) { line in
                Label { Text("Failed: \(line)") } icon: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }.font(.caption)
            }
            ForEach(r.skipped, id: \.self) { line in
                Label { Text("Skipped: \(line)") } icon: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }.font(.caption)
            }
            ForEach(r.notes, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        } else {
            Text("No import yet.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { BikeImportView() }
}
