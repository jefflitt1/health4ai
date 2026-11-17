import XCTest
import HealthKit
@testable import Health4AI

@MainActor
final class WorkoutDetailTests: XCTestCase {
    private let user = "00000000-0000-0000-0000-000000000001"
    private var identity: WorkoutDetailIdentity {
        WorkoutDetailIdentity(endpoint: "https://example.invalid/functions/v1/healthkit-ingest",
            userID: user, connectionRevision: 1, signOutGeneration: 2)
    }
    private func token(_ subject: String? = nil) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["sub": subject ?? user])
        return "e30." + data.base64EncodedString() + ".signature"
    }
    private func reply(_ request: URLRequest, _ json: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: json),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func sample(_ id: UUID = UUID(), source: String = "Watch") -> WorkoutDetailSample {
        WorkoutDetailSample(sampleUUID: id.uuidString, metricType: HKQuantityTypeIdentifier.stepCount.rawValue,
            value: 20, unit: "count", sourceDevice: source,
            startedAt: "2026-01-01T00:00:00.000Z", endedAt: "2026-01-01T00:01:00.000Z")
    }
    private var steps: HKQuantityType { HKObjectType.quantityType(forIdentifier: .stepCount)! }

    func testConsentDefaultsOffAndBindsUserAndDestination() {
        let suite = UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        XCTAssertFalse(prefs.bool(forKey: identity.consentKey))
        prefs.set(true, forKey: identity.consentKey)
        let other = WorkoutDetailIdentity(endpoint: identity.endpoint, userID: UUID().uuidString,
            connectionRevision: 1, signOutGeneration: 2)
        XCTAssertFalse(prefs.bool(forKey: other.consentKey))
        XCTAssertTrue(identity.consentKey.hasPrefix("hkb."))
        prefs.removeObject(forKey: identity.consentKey)
    }

    func testConfirmedDeletionCannotChangeAccountOrWidenToAll() throws {
        let id = UUID()
        let confirmation = WorkoutDetailDeletion(identity: identity, target: .workout(id), routes: false)
        let request = try confirmation.request(current: identity)
        XCTAssertEqual(request.operation, "delete")
        XCTAssertEqual(request.workoutUUID, id.uuidString.lowercased())
        XCTAssertThrowsError(try confirmation.request(current: nil))
        let changed = WorkoutDetailIdentity(endpoint: identity.endpoint, userID: user,
            connectionRevision: identity.connectionRevision + 1, signOutGeneration: identity.signOutGeneration)
        XCTAssertThrowsError(try confirmation.request(current: changed))
        XCTAssertEqual(try WorkoutDetailDeletion(identity: identity, target: .all, routes: true)
            .request(current: identity).operation, "delete_all")
    }

    func testOnlySecureExactSupabasePathAccepted() {
        for url in ["http://example.invalid/functions/v1/healthkit-ingest", "https://example.invalid/api/ingest",
                    "https://user:secret@example.invalid/functions/v1/healthkit-ingest", identity.endpoint + "?x=y"] {
            XCTAssertNil(WorkoutDetailIdentity(endpoint: url, userID: user,
                connectionRevision: 0, signOutGeneration: 0).detailURL)
        }
        XCTAssertEqual(identity.detailURL?.absoluteString, "https://example.invalid/functions/v1/workout-details")
    }

    func testScopeNeverExpandsPermissions() {
        let core = Set<HKSampleType>(WorkoutDetailHealthReader.queryTypes(scope: .essentials))
        XCTAssertTrue(core.isSubset(of: HealthKitManager.sampleTypes(for: .essentials)))
        XCTAssertEqual(WorkoutDetailHealthReader.queryTypes(scope: .complete).count, 7)
        XCTAssertFalse(core.contains(HKObjectType.quantityType(forIdentifier: .runningPower)!))
    }

    func testCanonicalUnitsAndSourceIntervalsPreservedWithoutMetadata() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for id in WorkoutDetailHealthReader.identifiers {
            let type = HKObjectType.quantityType(forIdentifier: id)!
            let unit = HealthKitManager.unitMap[id.rawValue]!
            let raw = HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: 3),
                start: start, end: start.addingTimeInterval(60), metadata: ["private": "omitted"])
            let out = try WorkoutDetailHealthReader.convert(raw)
            XCTAssertEqual(out.sampleUUID, raw.uuid.uuidString.lowercased())
            XCTAssertEqual(out.unit, unit.unitString)
            XCTAssertEqual(out.value, 3)
            let data = try JSONEncoder().encode(out)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        }
    }

    func testTokenRefreshChangingSessionCannotPost() async throws {
        for changed in [
            WorkoutDetailIdentity(endpoint: identity.endpoint, userID: user, connectionRevision: 3, signOutGeneration: 2),
            WorkoutDetailIdentity(endpoint: identity.endpoint, userID: user, connectionRevision: 1, signOutGeneration: 3),
            WorkoutDetailIdentity(endpoint: identity.endpoint, userID: UUID().uuidString, connectionRevision: 1, signOutGeneration: 2)
        ] {
            var current = identity
            let captured = identity
            var posts = 0
            let client = WorkoutDetailClient(identity: captured, token: {
                await Task.yield(); current = changed; return self.token()
            }, validate: { if current != captured { throw WorkoutDetailError.changed } }, transport: { request in
                posts += 1; return try self.reply(request, [:])
            })
            do { _ = try await client.send(WorkoutDetailRequest(operation: "capabilities")); XCTFail() }
            catch { XCTAssertEqual(posts, 0) }
        }
    }

    func testWrongJWTSubjectNeverPosts() async {
        var posts = 0
        let client = WorkoutDetailClient(identity: identity, token: { self.token(UUID().uuidString) }, validate: {},
            transport: { request in posts += 1; return try self.reply(request, [:]) })
        do { _ = try await client.send(WorkoutDetailRequest(operation: "delete_all")); XCTFail() }
        catch { XCTAssertEqual(posts, 0) }
    }

    func testLostResponseRetriesIdenticalPayloadOnce() async throws {
        var bodies: [Data] = []
        let client = WorkoutDetailClient(identity: identity, token: { self.token() }, validate: {}, transport: { request in
            bodies.append(request.httpBody!)
            if bodies.count == 1 { throw URLError(.networkConnectionLost) }
            return try self.reply(request, ["observed_count": 1])
        })
        _ = try await client.send(WorkoutDetailRequest(operation: "page", workoutUUID: UUID().uuidString,
            exportUUID: UUID().uuidString, samples: [sample()]))
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
    }

    func testConsentRevokedDuringResponseCannotRetry() async {
        var allowed = true, posts = 0
        let client = WorkoutDetailClient(identity: identity, token: { self.token() }, validate: {
            if !allowed { throw WorkoutDetailError.changed }
        }, transport: { _ in posts += 1; await Task.yield(); allowed = false; throw URLError(.timedOut) })
        do { _ = try await client.send(WorkoutDetailRequest(operation: "capabilities")); XCTFail() }
        catch { XCTAssertEqual(posts, 1) }
    }

    func testServerErrorIsNotRetriedOrPresentedAsSuccess() async {
        var posts = 0
        let client = WorkoutDetailClient(identity: identity, token: { self.token() }, validate: {}, transport: { request in
            posts += 1; return try self.reply(request, ["error": "private provider message"], status: 409)
        })
        do { _ = try await client.send(WorkoutDetailRequest(operation: "delete_all")); XCTFail() }
        catch { XCTAssertEqual(posts, 1); XCTAssertFalse(error.localizedDescription.contains("private provider")) }
    }

    func testDeleteDoesNotRequireExportConsent() async throws {
        let client = WorkoutDetailClient(identity: identity, token: { self.token() }, validate: {}, transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(Set(body.keys), ["operation"])
            XCTAssertEqual(body["operation"] as? String, "delete_all")
            return try self.reply(request, ["deleted_exports": 0])
        })
        let response = try await client.send(WorkoutDetailRequest(operation: "delete_all"))
        XCTAssertEqual(response.deletedExports, 0)
    }

    func testBoundedPagesAndFreshRevisionForEveryExplicitExport() async throws {
        var revisions: [String] = [], seen = Set<String>(), pageSizes: [Int] = []
        let client = WorkoutDetailClient(identity: identity, token: { self.token() }, validate: {}, transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertLessThanOrEqual(request.httpBody!.count, 256 * 1024)
            let revision = (body["export_uuid"] as? String ?? "").lowercased()
            switch body["operation"] as! String {
            case "capabilities": return try self.reply(request, ["capabilities": ["workout_details_v1"]])
            case "begin": revisions.append(revision); seen = []; return try self.reply(request, ["export_uuid": revision, "complete": false])
            case "page":
                let samples = body["samples"] as! [[String: Any]]; pageSizes.append(samples.count)
                for sample in samples { seen.insert(sample["sample_uuid"] as! String) }
                return try self.reply(request, ["observed_count": seen.count])
            default: return try self.reply(request, ["export_uuid": revision, "complete": true,
                "observed_count": seen.count, "coverage": "observed_only"])
            }
        })
        for _ in 0..<2 {
            var pages = 0
            let count = try await WorkoutDetailExport.run(workoutID: UUID(), types: [steps], client: client, validate: {}) { _, anchor in
                pages += 1
                if pages == 1 {
                    XCTAssertNil(anchor)
                    return WorkoutDetailHealthPage(samples: (0..<500).map { _ in self.sample(source: String(repeating: "é", count: 256)) },
                        anchor: HKQueryAnchor(fromValue: 1), hasMore: true)
                }
                XCTAssertNotNil(anchor)
                return WorkoutDetailHealthPage(samples: [self.sample()], anchor: HKQueryAnchor(fromValue: 2), hasMore: false)
            }
            XCTAssertEqual(count, 501)
        }
        XCTAssertEqual(Set(revisions).count, 2)
        XCTAssertTrue(pageSizes.allSatisfy { $0 <= 500 })
        XCTAssertGreaterThan(pageSizes.count, 4) // byte budget splits the 500 long-source rows
    }

    func testCancellationAfterHealthQueryDoesNotUploadOrFinalize() async throws {
        var allowed = true, operations: [String] = []
        let validate = { if !allowed { throw WorkoutDetailError.changed } }
        let client = WorkoutDetailClient(identity: identity, token: { self.token() }, validate: validate, transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let op = body["operation"] as! String; operations.append(op)
            return try self.reply(request, op == "capabilities" ? ["capabilities": ["workout_details_v1"]] :
                ["export_uuid": body["export_uuid"]!, "complete": false])
        })
        do {
            _ = try await WorkoutDetailExport.run(workoutID: UUID(), types: [steps], client: client, validate: validate) { _, _ in
                await Task.yield(); allowed = false
                return WorkoutDetailHealthPage(samples: [self.sample()], anchor: nil, hasMore: false)
            }
            XCTFail()
        } catch { XCTAssertEqual(operations, ["capabilities", "begin"]) }
    }

    func testEmptyObservationAndUnconfirmedFinalizeAreDistinct() async throws {
        for confirmed in [true, false] {
            var operations: [String] = []
            let client = WorkoutDetailClient(identity: identity, token: { self.token() }, validate: {}, transport: { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let op = body["operation"] as! String; operations.append(op)
                if op == "capabilities" { return try self.reply(request, ["capabilities": ["workout_details_v1"]]) }
                if op == "begin" { return try self.reply(request, ["export_uuid": body["export_uuid"]!, "complete": false]) }
                return try self.reply(request, ["export_uuid": body["export_uuid"]!, "complete": confirmed,
                    "observed_count": 0, "coverage": "observed_only"])
            })
            do {
                let count = try await WorkoutDetailExport.run(workoutID: UUID(), types: [steps], client: client,
                    validate: {}) { _, _ in WorkoutDetailHealthPage(samples: [], anchor: nil, hasMore: false) }
                XCTAssertTrue(confirmed)
                XCTAssertEqual(count, 0) // Real empty query; no inference about authorization.
            } catch { XCTAssertFalse(confirmed) }
            XCTAssertEqual(operations, ["capabilities", "begin", "finalize"])
        }
    }
}
