import Foundation
import os

// HTTP client for the Peloton Pi. The base URL has already passed BikeURLValidator. Redirects are
// refused: a LAN host that answers 302 to a public URL must not turn the app into an internet fetcher.

enum BikeClientError: Error, LocalizedError, Equatable {
    case unreachable(host: String, detail: String)
    case timedOut(host: String)
    case http(status: Int, path: String)
    case redirectRefused
    case badResponse(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreachable(let host, let detail):
            return "Could not reach the bike at \(host) (\(detail)). Check that it is on, that this phone is on the same "
                + "Wi-Fi, and that Local Network is allowed for health4ai in Settings."
        case .timedOut(let host):
            return "The bike at \(host) did not answer in time. Check that it is on and on the same Wi-Fi."
        case .http(let status, let path): return "The bike answered \(path) with HTTP \(status)."
        case .redirectRefused: return "The bike tried to redirect to another address, which is not allowed."
        case .badResponse(let why): return "That address answered, but not like a Peloton Pi (\(why))."
        case .tooLarge: return "The bike's response was unexpectedly large and was refused."
        }
    }
}

final class BikeHTTPClient: NSObject, BikeRideAPI, URLSessionTaskDelegate {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")
    static let maxBytes = 16 * 1024 * 1024

    private let baseURL: URL
    private var session: URLSession!

    init(baseURL: URL, timeout: TimeInterval = 8) {
        self.baseURL = baseURL
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func listRides() async throws -> [BikeRideSummary] {
        try decode(BikeRideList.self, from: try await get("api/rides")).rides
    }

    func ride(id: String) async throws -> BikeRide {
        guard BikeRideID.startDate(from: id) != nil else { throw BikeClientError.badResponse("ride id \(id)") }
        return try decode(BikeRide.self, from: try await get("api/rides/\(id)"))
    }

    private func get(_ path: String) async throws -> Data {
        var url = baseURL
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        let host = baseURL.host ?? "the bike"
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw BikeClientError.badResponse("not HTTP") }
            guard !(300..<400).contains(http.statusCode) else { throw BikeClientError.redirectRefused }
            guard (200..<300).contains(http.statusCode) else { throw BikeClientError.http(status: http.statusCode, path: "/" + path) }
            guard data.count <= Self.maxBytes else { throw BikeClientError.tooLarge }
            return data
        } catch let error as BikeClientError {
            Self.logger.error("GET /\(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        } catch let error as URLError {
            let mapped: BikeClientError
            switch error.code {
            case .timedOut: mapped = .timedOut(host: host)
            case .httpTooManyRedirects: mapped = .redirectRefused
            default: mapped = .unreachable(host: host, detail: error.localizedDescription)
            }
            Self.logger.error("GET /\(path, privacy: .public) failed: \(error.code.rawValue, privacy: .public)")
            throw mapped
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            Self.logger.error("decode \(String(describing: type), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw BikeClientError.badResponse("unexpected JSON")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        return nil   // nil = do not follow; the 3xx response comes back and is reported as .redirectRefused
    }
}
