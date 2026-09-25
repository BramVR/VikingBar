import Foundation

public struct TelenetCookieJar: Codable, Equatable, Sendable {
    private struct Cookie: Codable, Equatable, Sendable {
        let name: String
        let value: String
        let domain: String
        let hostOnly: Bool
        let path: String
        let expiresAt: Date?

        var valid: Bool {
            ["api.prd.telenet.be", "secure.telenet.be", "telenet.be", "prd.telenet.be"].contains(self.domain)
                && (!self.hostOnly || ["api.prd.telenet.be", "secure.telenet.be"].contains(self.domain))
                && !self.name.isEmpty && self.path.hasPrefix("/")
                && self.path.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
                && self.name.utf8.allSatisfy { $0 > 32 && $0 < 127 && ![59, 61, 44].contains($0) }
                && self.value.utf8.allSatisfy { $0 >= 32 && $0 < 127 && ![59, 13, 10].contains($0) }
                && self.name.utf8.count + self.value.utf8.count + self.path.utf8.count <= 8192
                && (self.expiresAt?.timeIntervalSince1970.isFinite ?? true)
        }

        func matches(_ host: String) -> Bool {
            ["api.prd.telenet.be", "secure.telenet.be"].contains(host)
                && (host == self.domain || (!self.hostOnly && host.hasSuffix("." + self.domain)))
        }
    }

    private var entries: [Cookie] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.entries = try container.decode([Cookie].self)
        try self.validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.entries)
    }

    public func usable(at now: Date) -> Bool {
        guard let url = URL(string: TelenetEndpoint.products) else { return false }
        return self.header(for: url, at: now) != nil
    }

    func header(for url: URL, at now: Date) -> String? {
        let values = self.entries.filter { cookie in
            cookie.matches(url.host ?? "") && url.scheme == "https" && (cookie.expiresAt.map { $0 > now } ?? true)
                && (url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/")
                        ? cookie.path : cookie.path + "/"))
        }.sorted { $0.path.count > $1.path.count }.map { $0.name + "=" + $0.value }
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    mutating func receive(_ response: TelenetResponse, from url: URL, at now: Date) throws {
        self.entries.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
        guard let field = response.header("Set-Cookie") else { return }
        guard field.utf8.count <= 32768, let host = url.host else { throw LiveFailure.malformedResponse }
        // Combined Set-Cookie headers contain commas inside Expires dates.
        let separated = field.replacingOccurrences(
            of: #",(?=\s*[^\s;,=]+\s*=)"#, with: "\n", options: .regularExpression,
        )
        for line in separated.components(separatedBy: .newlines) {
            let hostOnly = !line.split(separator: ";").dropFirst().contains {
                $0.split(separator: "=", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "domain"
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url) {
                let rawDomain = cookie.domain.lowercased()
                let domain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
                let entry = Cookie(
                    name: cookie.name, value: cookie.value, domain: domain, hostOnly: hostOnly, path: cookie.path,
                    expiresAt: cookie.expiresDate,
                )
                guard cookie.isSecure, entry.matches(host), entry.valid else { continue }
                self.entries.removeAll { $0.domain == domain && $0.name == entry.name && $0.path == entry.path }
                if entry.expiresAt.map({ $0 > now }) ?? true {
                    self.entries.append(entry)
                }
            }
        }
        try self.validate()
    }

    private func validate() throws {
        guard self.entries.count <= 64, self.entries.allSatisfy(\.valid),
              self.entries.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count + $1.path.utf8.count }) <= 32768,
              Set(self.entries.map { $0.domain + "\n" + $0.path + "\n" + $0.name }).count == self.entries.count
        else { throw LiveFailure.malformedResponse }
    }
}
