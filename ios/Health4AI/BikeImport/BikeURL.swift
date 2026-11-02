import Foundation

// Validation for the base URL of "Bike on your network". The app must never become a fetcher of
// arbitrary internet URLs and health4ai never receives health data, so the only hosts accepted
// are ones that cannot leave the user's LAN: `.local` (mDNS), RFC1918 IPv4, IPv4 link-local
// (169.254/16) and IPv6 link-local (fe80::/10). Loopback and everything else is rejected.

enum BikeURLError: Error, Equatable, LocalizedError {
    case empty
    case malformed
    case badScheme
    case noHost
    case credentialsNotAllowed
    case queryNotAllowed
    case publicHost(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter the address of your bike, for example http://peloton-pi.local:8080."
        case .malformed: return "That is not a valid web address."
        case .badScheme: return "Only http:// and https:// addresses are supported."
        case .noHost: return "The address has no host name."
        case .credentialsNotAllowed: return "Remove the user name and password from the address."
        case .queryNotAllowed: return "Remove everything after ? or # from the address."
        case .publicHost(let host):
            return "\(host) is not on your local network. Only .local names and private addresses "
                + "(10.x.x.x, 172.16-31.x.x, 192.168.x.x, 169.254.x.x) are allowed."
        }
    }
}

enum BikeURLValidator {
    /// Returns the normalised base URL (no trailing slash) or the reason it was refused.
    static func validate(_ raw: String) -> Result<URL, BikeURLError> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") { text = "http://" + text }
        guard let comps = URLComponents(string: text) else { return .failure(.malformed) }
        guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.badScheme)
        }
        guard comps.user == nil, comps.password == nil else { return .failure(.credentialsNotAllowed) }
        guard comps.query == nil, comps.fragment == nil else { return .failure(.queryNotAllowed) }
        guard var host = comps.host?.lowercased(), !host.isEmpty else { return .failure(.noHost) }
        if host.hasSuffix(".") { host.removeLast() }
        // URLComponents returns IPv6 literals bracketed; test the bare address, keep the original for output.
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard isLocalHost(bare) else { return .failure(.publicHost(host)) }
        var out = comps
        out.scheme = scheme
        out.host = host
        while out.path.hasSuffix("/") { out.path.removeLast() }
        guard let url = out.url else { return .failure(.malformed) }
        return .success(url)
    }

    static func isLocalHost(_ host: String) -> Bool {
        if let v4 = ipv4Octets(host) { return isPrivateOrLinkLocal(v4) }
        if host.contains(":") { return isIPv6LinkLocal(host) }
        // mDNS name: at least one label before ".local", and no stray characters.
        guard host.hasSuffix(".local"), host.count > ".local".count else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Strict dotted-quad: exactly four decimal parts of 1-3 digits, each 0...255.
    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(part.count > 1 && part.first == "0"),   // "010" is octal to some resolvers: ambiguous, refuse
                  let n = Int(part), n <= 255 else { return nil }
            out.append(n)
        }
        return out
    }

    private static func isPrivateOrLinkLocal(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    /// fe80::/10 (first group fe80...febf). A zone suffix (%en0) is tolerated.
    private static func isIPv6LinkLocal(_ host: String) -> Bool {
        let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard let first = bare.split(separator: ":", omittingEmptySubsequences: true).first,
              first.count == 4, let value = UInt16(first, radix: 16) else { return false }
        return value & 0xffc0 == 0xfe80
    }
}
