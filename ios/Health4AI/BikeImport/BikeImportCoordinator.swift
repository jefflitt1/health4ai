import Foundation
import os

// App-facing state for "Bike on your network": settings (off by default), the opt-in permission
// flow, the foreground trigger and the last result. The import itself lives in BikeImporter.
// Background: the app's existing BGAppRefreshTask only runs the health sync, and an import needs
// the phone on the home Wi-Fi with Local Network access, which a background launch cannot be
// counted on to have. So this runs on foreground plus "Import now", and is not hooked into it.

@MainActor
final class BikeImportCoordinator: ObservableObject {
    static let shared = BikeImportCoordinator()
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")

    enum Keys {
        static let enabled = "h4a.bike.enabled"
        static let url = "h4a.bike.url"
        static let lastResult = "h4a.bike.lastResult"   // display only; de-duplication reads Health
    }

    @Published private(set) var isEnabled: Bool
    @Published var urlText: String
    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: BikeImportResult?
    @Published private(set) var testMessage: String?
    @Published private(set) var testFailed = false
    @Published private(set) var setupError: String?
    @Published private(set) var writeStatus: BikeWriteStatus = .notDetermined

    private let defaults: UserDefaults
    private let store: BikeWorkoutStore
    private let makeAPI: (URL) -> BikeRideAPI

    init(defaults: UserDefaults = .standard,
         store: BikeWorkoutStore = HealthKitBikeStore(),
         makeAPI: @escaping (URL) -> BikeRideAPI = { BikeHTTPClient(baseURL: $0) }) {
        self.defaults = defaults
        self.store = store
        self.makeAPI = makeAPI
        isEnabled = defaults.bool(forKey: Keys.enabled)
        urlText = defaults.string(forKey: Keys.url) ?? ""
        if let data = defaults.data(forKey: Keys.lastResult) {
            lastResult = try? JSONDecoder().decode(BikeImportResult.self, from: data)
        }
        writeStatus = store.workoutWriteStatus
    }

    var urlValidation: Result<URL, BikeURLError> { BikeURLValidator.validate(urlText) }
    var urlError: String? {
        if urlText.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if case .failure(let e) = urlValidation { return e.localizedDescription }
        return nil
    }

    func refreshStatus() { writeStatus = store.workoutWriteStatus }

    // MARK: Opt-in

    /// Turning on validates the address, then asks Health for WRITE access. Only if that leaves the
    /// workout type authorized does the switch stay on.
    func setEnabled(_ on: Bool) async {
        setupError = nil
        guard on else {
            isEnabled = false
            defaults.set(false, forKey: Keys.enabled)
            return
        }
        guard case .success(let url) = urlValidation else {
            setupError = urlError ?? BikeURLError.empty.localizedDescription
            return
        }
        do { try await store.requestCoreAuthorization() } catch {
            Self.logger.error("write authorization failed: \(error.localizedDescription, privacy: .public)")
            setupError = "Health write access could not be requested: \(error.localizedDescription)"
            refreshStatus()
            return
        }
        refreshStatus()
        guard writeStatus == .authorized else {
            Self.logger.error("write authorization not granted: \(String(describing: self.writeStatus), privacy: .public)")
            setupError = writeStatus == .denied ? BikeImportError.permissionDenied.localizedDescription
                                                : BikeImportError.permissionNotRequested.localizedDescription
            return
        }
        urlText = url.absoluteString
        defaults.set(url.absoluteString, forKey: Keys.url)
        isEnabled = true
        defaults.set(true, forKey: Keys.enabled)
        await importNow()
    }

    // MARK: Test + import

    func testConnection() async {
        testMessage = nil
        testFailed = false
        guard case .success(let url) = urlValidation else {
            testFailed = true
            testMessage = urlError ?? BikeURLError.empty.localizedDescription
            return
        }
        do {
            let rides = try await makeAPI(url).listRides()
            testMessage = "Connected. The bike has \(rides.count) ride\(rides.count == 1 ? "" : "s")."
        } catch {
            testFailed = true
            testMessage = error.localizedDescription
            Self.logger.error("test connection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func importOnForeground() async {
        guard isEnabled else { return }
        await importNow()
    }

    func importNow() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let result: BikeImportResult
        if case .success(let url) = urlValidation {
            result = await BikeImporter(api: makeAPI(url), store: store).run()
        } else {
            var r = BikeImportResult(date: Date())
            r.error = urlError ?? BikeURLError.empty.localizedDescription
            result = r
        }
        refreshStatus()
        lastResult = result
        if let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: Keys.lastResult) }
        Self.logger.info("import: \(result.imported) new, \(result.alreadyImported) existing, \(result.skipped.count) skipped, \(result.failed.count) failed, error=\(result.error ?? "none", privacy: .public)")
        for line in result.failed + result.skipped { Self.logger.error("\(line, privacy: .public)") }
    }
}
