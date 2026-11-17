import SwiftUI
import HealthKit

@MainActor
final class WorkoutDetailModel: ObservableObject {
    @Published private(set) var workouts: [HKWorkout] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published private(set) var consent = false
    @Published private(set) var routeConsent = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var identity: WorkoutDetailIdentity?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func identity(sync: SyncState, auth: AuthManager,
                         defaults: UserDefaults = .standard) -> WorkoutDetailIdentity? {
        guard sync.connectionType == .supabase, sync.isAuthenticated,
              let user = defaults.string(forKey: "hkb.healthkitUserID"), UUID(uuidString: user) != nil else { return nil }
        let identity = WorkoutDetailIdentity(endpoint: sync.resolvedEndpointURL, userID: user,
            connectionRevision: sync.connectionRevision, signOutGeneration: auth.signOutGeneration)
        return identity.detailURL == nil ? nil : identity
    }

    func update(sync: SyncState, auth: AuthManager) {
        let next = Self.identity(sync: sync, auth: auth, defaults: defaults)
        if next != identity {
            stop()
            workouts = []
            message = nil
        }
        identity = next
        consent = next.map { defaults.bool(forKey: $0.consentKey) } ?? false
        routeConsent = next.map { defaults.bool(forKey: $0.consentKey + ".routes") } ?? false
    }

    func setConsent(_ enabled: Bool) {
        guard let identity else { return }
        defaults.set(enabled, forKey: identity.consentKey)
        consent = enabled
        if !enabled { stop() }
    }

    func stop() {
        generation += 1
        task?.cancel()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-h4aiScreenshotWorkoutDetails") { busy = false }
        #endif
        // Keep busy until the outstanding request returns. Deletion cannot race it.
    }

    func setRouteConsent(_ enabled: Bool, sync: SyncState, auth: AuthManager) {
        guard let identity else { return }
        if !enabled {
            defaults.set(false, forKey: identity.consentKey + ".routes")
            routeConsent = false
            stop()
            return
        }
        operate(sync: sync, auth: auth, needsConsent: false, routes: true) { [weak self] client, validate in
            let capability = try await client.send(WorkoutDetailRequest(operation: "capabilities"))
            try validate()
            guard capability.capabilities?.contains("workout_routes_v1") == true else { throw WorkoutDetailError.unavailable }
            try await WorkoutRouteReader.requestPermission()
            try validate()
            self?.defaults.set(true, forKey: identity.consentKey + ".routes")
            self?.routeConsent = true
            return "Route export enabled for this account. Health permissions remain your choice; no route " +
                "has been exported."
        }
    }

    func exportRoute(_ workout: HKWorkout, sync: SyncState, auth: AuthManager) {
        operate(sync: sync, auth: auth, needsConsent: false, routes: true, needsRouteConsent: true) { client, validate in
            try validate()
            let capability = try await client.send(WorkoutDetailRequest(operation: "capabilities"))
            try validate()
            guard capability.capabilities?.contains("workout_routes_v1") == true else { throw WorkoutDetailError.unavailable }
            let routes = try await WorkoutRouteReader.routes(workout: workout)
            try validate()
            let descriptors = routes.map { WorkoutRouteDescriptor(routeUUID: $0.uuid.uuidString.lowercased(), sourceCount: $0.count) }
            let summary = try await WorkoutRouteExport.run(workoutID: workout.uuid, routes: descriptors,
                client: client, validate: validate) { descriptor in
                guard let route = routes.first(where: { $0.uuid.uuidString.lowercased() == descriptor.routeUUID }) else {
                    throw WorkoutDetailError.healthChanged
                }
                return try await WorkoutRouteReader.observation(route)
            }
            return "Server confirmed \(summary.valid) stored route points from \(summary.source) observed " +
                "points; \(summary.invalid) invalid points were omitted. Empty results do not prove " +
                "permission or absence."
        }
    }

    func load(sync: SyncState, auth: AuthManager) {
        operate(sync: sync, auth: auth, needsConsent: false) { [weak self] _, validate in
            try validate()
            let workouts = try await WorkoutDetailHealthReader.workouts()
            try validate()
            self?.workouts = workouts
            return workouts.isEmpty ? "No running workouts were returned. This does not prove read permission or absence of workouts." : "Choose one of your 30 most recent running workouts."
        }
    }

    func export(_ workout: HKWorkout, sync: SyncState, auth: AuthManager) {
        let types = WorkoutDetailHealthReader.queryTypes(scope: HealthKitManager.selectedScope)
        operate(sync: sync, auth: auth, needsConsent: true) { client, validate in
            let count = try await WorkoutDetailExport.run(workoutID: workout.uuid, types: types,
                client: client, validate: validate) { type, anchor in
                try await WorkoutDetailHealthReader.page(workout: workout, type: type, anchor: anchor)
            }
            return "Server confirmed a completed export of \(count) observed samples. This is not proof of " +
                "complete Health data or read permission."
        }
    }

    func delete(_ confirmed: WorkoutDetailDeletion, sync: SyncState, auth: AuthManager) {
        guard Self.identity(sync: sync, auth: auth, defaults: defaults) == confirmed.identity else {
            failed = true; message = WorkoutDetailError.changed.errorDescription; return
        }
        operate(sync: sync, auth: auth, needsConsent: false, routes: confirmed.routes) { client, validate in
            let request = try confirmed.request(current: Self.identity(sync: sync, auth: auth, defaults: self.defaults))
            let response = try await client.send(request)
            try validate()
            guard let count = response.deletedExports, count >= 0 else { throw WorkoutDetailError.invalidResponse }
            return confirmed.routes ? "Server confirmed deletion of \(count) route revisions and their coordinates. Quantity " +
                "detail exports and Health records remain." :
                "Server confirmed deletion of \(count) quantity detail revisions. Routes, Health records " +
                    "and ordinary synced metrics remain."
        }
    }

    private func operate(sync: SyncState, auth: AuthManager, needsConsent: Bool,
        routes: Bool = false, needsRouteConsent: Bool = false,
        work: @escaping (WorkoutDetailClient, @escaping () throws -> Void) async throws -> String) {
        guard !busy else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-h4aiScreenshotWorkoutDetails") {
            message = "Design fixture only. No Health query or server operation was performed."
            return
        }
        #endif
        update(sync: sync, auth: auth)
        guard let captured = identity else { return }
        let operation = generation
        let scope = HealthKitManager.selectedScope
        let validate = { [weak self] in
            guard let self, !Task.isCancelled, self.generation == operation,
                  Self.identity(sync: sync, auth: auth, defaults: self.defaults) == captured,
                  HealthKitManager.selectedScope == scope,
                  !needsConsent || self.defaults.bool(forKey: captured.consentKey),
                  !needsRouteConsent || self.defaults.bool(forKey: captured.consentKey + ".routes") else {
                throw WorkoutDetailError.changed
            }
        }
        let client = WorkoutDetailClient(identity: captured,
            token: { try validate(); return try await auth.validToken(serverURL: captured.endpoint) },
            validate: validate, resource: routes ? .routes : .details)
        busy = true
        message = "Working…"
        failed = false
        task = Task {
            defer { busy = false; task = nil }
            do {
                try validate()
                let result = try await work(client, validate)
                try validate()
                message = result
            } catch {
                // Never display raw transport/provider errors or Health sample values.
                failed = true
                message = (error as? WorkoutDetailError)?.errorDescription
                    ?? "The operation was not confirmed. Unlock your phone and check the connection before trying again."
            }
        }
    }

    #if DEBUG
    func configureFixture(sync: SyncState, auth: AuthManager) -> HKWorkout? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-h4aiScreenshotWorkoutDetails") else { return nil }
        if args.contains("-h4aiWorkoutUnsupported") { sync.isAuthenticated = false; update(sync: sync, auth: auth); return nil }
        sync.connectionType = .supabase
        sync.supabaseProjectURL = "https://example.invalid"
        sync.isAuthenticated = true
        defaults.set("00000000-0000-0000-0000-000000000001", forKey: "hkb.healthkitUserID")
        update(sync: sync, auth: auth)
        consent = !args.contains("-h4aiWorkoutOff")
        routeConsent = args.contains("-h4aiWorkoutRoutesOn")
        if let identity {
            defaults.set(consent, forKey: identity.consentKey)
            defaults.set(routeConsent, forKey: identity.consentKey + ".routes")
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(1800))
        workouts = [workout]
        if args.contains("-h4aiWorkoutSuccess") { message = "Server confirmed a completed export of 501 observed samples. This is not proof of " +
            "complete Health data or read permission." }
        if args.contains("-h4aiWorkoutFailure") { failed = true; message = WorkoutDetailError.unavailable.errorDescription }
        if args.contains("-h4aiWorkoutBusy") { busy = true; message = "Working…" }
        return args.contains("-h4aiWorkoutUnselected") ? nil : workout
    }
    #endif
}
