import Foundation

private final class WorkoutDetailRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class WorkoutDetailClient {
    enum Resource: String { case details = "workout-details", routes = "workout-routes" }
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let identity: WorkoutDetailIdentity
    private let token: () async throws -> String
    private let validate: () throws -> Void
    private let transport: Transport
    private let resource: Resource

    init(identity: WorkoutDetailIdentity, token: @escaping () async throws -> String,
         validate: @escaping () throws -> Void, resource: Resource = .details, transport: Transport? = nil) {
        self.identity = identity
        self.token = token
        self.validate = validate
        self.resource = resource
        let session = URLSession(configuration: .ephemeral,
                                 delegate: WorkoutDetailRedirectPolicy(), delegateQueue: nil)
        self.transport = transport ?? { try await session.data(for: $0) }
    }

    func send(_ body: WorkoutDetailRequest) async throws -> WorkoutDetailResponse {
        try validate()
        guard let detailURL = identity.detailURL else { throw WorkoutDetailError.unsupported }
        let url = detailURL.deletingLastPathComponent().appendingPathComponent(resource.rawValue)
        // Encode once. A lost-response retry never re-queries HealthKit or changes this page.
        let bytes = try body.data()
        let bearer = try await token()
        try validate()
        guard Self.subject(bearer)?.lowercased() == identity.userID.lowercased() else {
            throw WorkoutDetailError.changed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.httpBody = bytes
        for attempt in 0...1 {
            try validate()
            do {
                let (data, response) = try await transport(request)
                try validate()
                guard let http = response as? HTTPURLResponse else { throw WorkoutDetailError.invalidResponse }
                if http.statusCode == 404 { throw WorkoutDetailError.unavailable }
                guard (200...299).contains(http.statusCode) else { throw WorkoutDetailError.server(http.statusCode) }
                guard data.count <= 64 * 1024 else { throw WorkoutDetailError.invalidResponse }
                return try JSONDecoder().decode(WorkoutDetailResponse.self, from: data)
            } catch let error as URLError where attempt == 0 &&
                [.timedOut, .networkConnectionLost].contains(error.code) {
                try validate()
            }
        }
        throw WorkoutDetailError.invalidResponse
    }

    private static func subject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: value),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return object["sub"] as? String
    }
}
