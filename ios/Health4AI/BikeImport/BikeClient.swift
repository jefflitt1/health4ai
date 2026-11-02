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
        case .tooLarge: return "The bike's response was larger than the 16 MB limit and was refused."
        }
    }
}

/// Session delegate kept separate from the client: a URLSession retains its delegate until it is
/// invalidated, so using the client itself as delegate made a retain cycle that leaked a session per use.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil   // do not follow; the 3xx response comes back and is reported as .redirectRefused
    }
}

final class BikeHTTPClient: BikeRideAPI {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")

    private static let blockSize = 64 * 1024
    private let baseURL: URL
    private let maxBytes: Int
    private let session: URLSession

    /// `protocolClasses` exists so tests can serve canned responses.
    init(baseURL: URL, timeout: TimeInterval = 8, maxBytes: Int = BikeLimits.maxBytes, protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        self.maxBytes = maxBytes
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    /// Releases the session. Also done on deinit; callable early.
    func invalidate() { session.finishTasksAndInvalidate() }
    deinit { session.invalidateAndCancel() }

    func listRides() async throws -> [BikeRideSummary] {
        try decode(BikeRideList.self, from: try await get("api/rides")).rides
    }

    func ride(id: String) async throws -> BikeRide {
        guard BikeRideID.startDate(from: id) != nil else {
            Self.logger.error("refused a ride id that is not a timestamp: \(id, privacy: .public)")
            throw BikeClientError.badResponse("a ride id it cannot read")
        }
        return try decode(BikeRide.self, from: try await get("api/rides/\(id)", shownAs: "/api/rides/(this ride)"))
    }

    /// `shownAs` is the path used in messages the person sees, so a raw ride id never reaches the screen.
    private func get(_ path: String, shownAs: String? = nil) async throws -> Data {
        var url = baseURL
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        let host = baseURL.host ?? "the bike"
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { throw BikeClientError.badResponse("not HTTP") }
            guard !(300..<400).contains(http.statusCode) else { throw BikeClientError.redirectRefused }
            guard (200..<300).contains(http.statusCode) else { throw BikeClientError.http(status: http.statusCode, path: shownAs ?? "/" + path) }
            // Refuse on the declared length before reading anything, then enforce the cap while streaming
            // (a server can lie or omit the length).
            guard response.expectedContentLength <= Int64(maxBytes) else { throw BikeClientError.tooLarge }
            // The read still iterates byte by byte; only the APPEND is batched. Appending to Data one byte
            // at a time was the slow part on a multi-MB ride, so bytes collect in a block that is appended
            // 64 KB at a time. The cap is checked per byte.
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(min(response.expectedContentLength, Int64(maxBytes)))) }
            var block = [UInt8]()
            block.reserveCapacity(Self.blockSize)
            for try await byte in bytes {
                block.append(byte)
                if data.count + block.count > maxBytes { throw BikeClientError.tooLarge }
                if block.count == Self.blockSize { data.append(contentsOf: block); block.removeAll(keepingCapacity: true) }
            }
            data.append(contentsOf: block)
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
}
