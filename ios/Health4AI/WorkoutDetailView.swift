import SwiftUI
import HealthKit

struct WorkoutDetailView: View {
    @EnvironmentObject var sync: SyncState
    @EnvironmentObject var auth: AuthManager
    @StateObject private var model = WorkoutDetailModel()
    @State private var selected: HKWorkout?
    @State private var pendingDeletion: WorkoutDetailDeletion?

    private var identity: WorkoutDetailIdentity? { WorkoutDetailModel.identity(sync: sync, auth: auth) }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Text("Manually export a run’s heart rate, running dynamics and steps to your Supabase project. " +
                        "Off by default; requires the optional server extension.")
                }
                if identity != nil {
                    Section("Off by default") {
                        Toggle("Allow manual detail export", isOn: Binding(get: { model.consent }, set: model.setConsent))
                        Text("Uses your existing Health permissions. Turning off stops new exports, but does not delete " +
                            "stored data.").font(.caption)
                    }.id("consent")
                    selectionSection.id("selection")
                    Section("Delete quantity details") {
                        Button("Delete selected run’s details", role: .destructive) { confirm(all: false, routes: false) }
                            .frame(minHeight: 44).disabled(selected == nil || model.busy)
                        Button("Delete all quantity details", role: .destructive) { confirm(all: true, routes: false) }
                            .frame(minHeight: 44).disabled(model.busy)
                        Text("Available with export off. Routes, Health records and ordinary synced metrics remain.").font(.caption)
                    }.id("delete")
                    routeSection.id("routes")
                } else {
                    Section { Text("Connect and sign in to your Supabase destination to use this feature. Other destinations " +
                        "are not supported.") }
                }
                if let message = model.message {
                    Section("Status") {
                        Label(message, systemImage: model.failed ? "exclamationmark.circle" : "info.circle")
                            .accessibilityLabel(message)
                        if model.busy { Button("Cancel operation") { model.stop() }.frame(minHeight: 44) }
                    }.id("status")
                }
                Section {
                    DisclosureGroup("Export limits and data coverage") {
                        Text("Requires the optional server extension. Quantities include heart rate, running dynamics " +
                            "and steps within your existing Health scope. GPS has separate consent. Structured JSON is " +
                            "available through your server’s MCP; FIT files are not included.")
                        Text("Each export starts a new revision. Your server retains up to 16 per workout, including " +
                            "incomplete attempts. Interrupted exports do not resume across launches.")
                        Text("Separate Health queries are not an atomic snapshot. Empty data does not prove permission " +
                            "or absence. Raw steps from multiple devices must not be summed as a merged total. Invalid " +
                            "route points are counted and omitted.")
                        Text("Local erase does not delete server data, backups or copies already shared with an AI " +
                            "provider. Use both deletion sections to remove quantities and coordinates.")
                    }
                }
            }
            .navigationTitle("Workout details")
            .sheet(item: $pendingDeletion) { confirmation in deletionSheet(confirmation) }
            .onAppear {
                model.update(sync: sync, auth: auth)
                #if DEBUG
                selected = model.configureFixture(sync: sync, auth: auth)
                #endif
            }
            .task(id: identity) {
                #if DEBUG
                await prepareScreenshot(proxy)
                #endif
            }
            .onChange(of: identity) { _, _ in
                pendingDeletion = nil
                selected = nil
                model.update(sync: sync, auth: auth)
                #if DEBUG
                selected = model.configureFixture(sync: sync, auth: auth)
                #endif
            }
            .onDisappear { model.stop() }
        }
    }

    private var selectionSection: some View {
        Section("Select a running workout") {
            Button("Load recent runs") { model.load(sync: sync, auth: auth) }
                .frame(minHeight: 44).disabled(model.busy)
            ForEach(model.workouts, id: \.uuid) { workout in
                Button { selected = workout } label: {
                    VStack(alignment: .leading) {
                        Text(workout.startDate, format: .dateTime.month().day().year().hour().minute())
                        Text(selected?.uuid == workout.uuid ? "Selected" : "Select run").font(.caption)
                    }.frame(minHeight: 44)
                }.disabled(model.busy)
            }
            Button("Export selected run") {
                if let selected { model.export(selected, sync: sync, auth: auth) }
            }
            .buttonStyle(.borderedProminent).tint(.pink).frame(minHeight: 44)
            .disabled(!model.consent || selected == nil || model.busy)
        }
    }

    private var routeSection: some View {
        Section("GPS routes — separate consent") {
            Text("Precise locations can reveal your home and movements. Routes go to your own Supabase " +
                "project and stay there until you delete them.")
            Toggle("Allow manual route export", isOn: Binding(get: { model.routeConsent }, set: {
                model.setRouteConsent($0, sync: sync, auth: auth)
            }))
            Text("Turning on requests read-only route permission after checking server support. It does not " +
                "export a route.").font(.caption)
            Button("Export selected run’s route") {
                if let selected { model.exportRoute(selected, sync: sync, auth: auth) }
            }.frame(minHeight: 44).disabled(!model.routeConsent || selected == nil || model.busy)
            Button("Delete selected run’s routes", role: .destructive) { confirm(all: false, routes: true) }
                .frame(minHeight: 44).disabled(selected == nil || model.busy)
            Button("Delete all routes for this account", role: .destructive) { confirm(all: true, routes: true) }
                .frame(minHeight: 44).disabled(model.busy)
            Text("Route deletion works with consent off. Quantity detail exports remain.").font(.caption)
        }
    }

    private func confirm(all: Bool, routes: Bool) {
        guard let identity else { return }
        let target: WorkoutDetailDeletion.Target
        if all { target = .all }
        else if let selected { target = .workout(selected.uuid) }
        else { return }
        pendingDeletion = WorkoutDetailDeletion(identity: identity, target: target, routes: routes)
    }

    private func deletionSheet(_ confirmation: WorkoutDetailDeletion) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(deletionAction(confirmation) + "?").font(.title2.bold())
                    Text("Deletes every stored revision in this scope. Cannot be undone. Health records stay intact.")
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button(deletionAction(confirmation), role: .destructive) {
                        model.delete(confirmation, sync: sync, auth: auth)
                        pendingDeletion = nil
                    }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(identity != confirmation.identity)
                    Button("Cancel", role: .cancel) { pendingDeletion = nil }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.padding().background(Color(.systemBackground))
            }
            .navigationTitle("Confirm deletion")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }

    private func deletionAction(_ confirmation: WorkoutDetailDeletion) -> String {
        let category = confirmation.routes ? "routes" : "details"
        switch confirmation.target {
        case .all: return "Delete all \(category)"
        case .workout: return "Delete run’s \(category)"
        }
    }

    #if DEBUG
    private func prepareScreenshot(_ proxy: ScrollViewProxy) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-h4aiScreenshotWorkoutDetails") else { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        if let flag = args.first(where: { $0.hasPrefix("-h4aiWorkoutSection=") }) {
            let anchor: UnitPoint = args.contains("-h4aiWorkoutAnchor=bottom") ? .bottom : .top
            proxy.scrollTo(String(flag.split(separator: "=").last!), anchor: anchor)
        }
        if args.contains("-h4aiWorkoutDeleteDialog") { confirm(all: false, routes: false) }
        if args.contains("-h4aiWorkoutRouteDeleteDialog") { confirm(all: true, routes: true) }
        if args.contains("-h4aiWorkoutSelectedRouteDeleteDialog") { confirm(all: false, routes: true) }
    }
    #endif
}
