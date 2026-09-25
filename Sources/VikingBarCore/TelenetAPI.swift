import Foundation

public struct TelenetHomePayload: Sendable {
    public let cycle: Data
    public let usage: Data
    public let dailyUsage: Data?
    public let dailyFailure: LiveFailure?
    public let dailyRetryAfter: Date?

    public init(
        cycle: Data, usage: Data, dailyUsage: Data? = nil,
        dailyFailure: LiveFailure? = nil, dailyRetryAfter: Date? = nil,
    ) {
        self.cycle = cycle
        self.usage = usage
        self.dailyUsage = dailyUsage
        self.dailyFailure = dailyFailure
        self.dailyRetryAfter = dailyRetryAfter
    }
}

public actor TelenetAPI {
    public private(set) var cookies: TelenetCookieJar
    let transport: any TelenetTransport
    let now: @Sendable () -> Date
    private let started = ContinuousClock.now
    private var requests = 0
    private var services: Set<String> = []
    private var busy = false
    private var loginAttempted = false

    public init(
        transport: any TelenetTransport = EphemeralTelenetTransport(),
        cookies: TelenetCookieJar = .init(), now: @escaping @Sendable () -> Date = Date.init,
    ) {
        self.transport = transport
        self.cookies = cookies
        self.now = now
    }

    public func login(credentials: TelenetCredentials) async throws {
        try credentials.validate()
        guard !self.busy else { throw LiveFailure.busy }
        guard !self.loginAttempted else { throw LiveFailure.reconnectRequired }
        self.busy = true
        self.loginAttempted = true
        defer { self.busy = false }
        self.cookies = TelenetCookieJar()
        try await self.authenticate(credentials)
    }

    public func discover() async throws -> [String] {
        guard !self.busy else { throw LiveFailure.busy }
        self.busy = true
        defer { self.busy = false }
        self.services = []
        let response = try await self.send("GET", TelenetEndpoint.products)
        guard let products = try Self.json(response) as? [[String: Any]], products.count <= 64 else {
            throw LiveFailure.malformedResponse
        }
        var ids: [String] = []
        for product in products {
            guard let kind = product["productType"] as? String else { throw LiveFailure.malformedResponse }
            if kind.lowercased() == "bundle" {
                guard let children = product["products"] as? [[String: Any]], children.count <= 64 else {
                    throw LiveFailure.malformedResponse
                }
                for child in children {
                    let childKind = try Self.productKind(child)
                    if childKind.lowercased() == "internet" {
                        try ids.append(Self.serviceID(child))
                    }
                }
            } else if kind.lowercased() == "internet" {
                try ids.append(Self.serviceID(product))
            }
        }
        guard !ids.isEmpty, ids.count <= 8, Set(ids).count == ids.count else { throw LiveFailure.malformedResponse }
        self.services = Set(ids)
        return ids
    }

    public func read(serviceID: String) async throws -> TelenetHomePayload {
        guard !self.busy else { throw LiveFailure.busy }
        guard self.services.contains(serviceID) else { throw LiveFailure.invalidSelection }
        self.busy = true
        defer { self.busy = false }
        let cycle = try await self.send(
            "GET", TelenetEndpoint.api + "/ocapi/public/api/billing-service/v1/account/products/"
                + serviceID + "/billcycle-details?producttype=internet&count=3",
        )
        guard let object = try Self.json(cycle) as? [String: Any],
              let cycles = object["billCycles"] as? [[String: Any]], let current = cycles.first,
              let start = current["startDate"] as? String, let end = current["endDate"] as? String,
              TelenetEndpoint.day(start), TelenetEndpoint.day(end), start <= end
        else { throw LiveFailure.malformedResponse }
        let prefix = TelenetEndpoint.api + "/ocapi/public/api/product-service/v1/products/internet/" + serviceID
        let dates = "fromDate=" + start + "&toDate=" + end
        let usage = try await self.send("GET", prefix + "/usage?" + dates)
        _ = try Self.json(usage)
        do {
            let daily = try await self.send("GET", prefix + "/dailyusage?billcycle=CURRENT&" + dates)
            _ = try Self.json(daily)
            return TelenetHomePayload(cycle: cycle.body, usage: usage.body, dailyUsage: daily.body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TelenetRequestFailure {
            if [.unauthorized, .reconnectRequired].contains(error.failure) {
                throw error
            }
            return TelenetHomePayload(
                cycle: cycle.body, usage: usage.body, dailyFailure: error.failure, dailyRetryAfter: error.retryAfter,
            )
        } catch let failure as LiveFailure {
            if [.unauthorized, .reconnectRequired].contains(failure) {
                throw failure
            }
            return TelenetHomePayload(cycle: cycle.body, usage: usage.body, dailyFailure: failure)
        }
    }

    func send(_ method: String, _ address: String, body: [String: Any]? = nil) async throws -> TelenetResponse {
        guard let url = URL(string: address), self.requests < 64 else { throw LiveFailure.requestDenied }
        let elapsed = self.started.duration(to: .now)
        guard elapsed < .seconds(150) else { throw LiveFailure.transport }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(12, 150 - Double(elapsed.components.seconds)
            - Double(elapsed.components.attoseconds) / 1e18)
        request.setValue("VikingBar-Telenet/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html", forHTTPHeaderField: "Accept")
        request.setValue("https://www2.telenet.be", forHTTPHeaderField: "Origin")
        request.setValue("https://www2.telenet.be", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www2.telenet.be/residential/nl/mijn-telenet/", forHTTPHeaderField: "x-alt-referer")
        request.setValue(self.cookies.header(for: url, at: self.now()), forHTTPHeaderField: "Cookie")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        try TelenetEndpoint.validate(request)
        self.requests += 1
        let response: TelenetResponse
        do { response = try await self.transport.send(request) } catch is CancellationError {
            throw CancellationError()
        } catch let failure as TelenetRequestFailure { throw failure } catch let failure as LiveFailure {
            throw failure
        } catch { throw LiveFailure.transport }
        guard response.body.count <= TelenetEndpoint.maximumBody,
              response.headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 65536
        else { throw LiveFailure.malformedResponse }
        try self.cookies.receive(response, from: url, at: self.now())
        if response.status == 429 || (500 ... 599).contains(response.status) {
            throw TelenetRequestFailure(
                failure: response.status == 429 ? .rateLimited : .serverUnavailable,
                retryAfter: Self.retryAfter(response.header("Retry-After"), now: self.now()),
            )
        }
        return response
    }

    static func json(_ response: TelenetResponse) throws -> Any {
        guard response.status == 200 else {
            if [401, 403].contains(response.status) {
                throw LiveFailure.unauthorized
            }
            if (300 ... 399).contains(response.status) {
                throw LiveFailure.reconnectRequired
            }
            throw LiveFailure.malformedResponse
        }
        do { return try JSONSerialization.jsonObject(with: response.body) } catch { throw LiveFailure.malformedResponse
        }
    }

    static func state(_ object: [String: Any]) throws -> String {
        guard let value = object["stateHandle"] as? String, !value.isEmpty, value.utf8.count <= 8192 else {
            throw LiveFailure.malformedResponse
        }
        return value
    }

    private static func serviceID(_ object: [String: Any]) throws -> String {
        guard let id = object["identifier"] as? String, TelenetEndpoint.identifier(id) else {
            throw LiveFailure.malformedResponse
        }
        return id
    }

    private static func productKind(_ object: [String: Any]) throws -> String {
        guard let kind = object["productType"] as? String else { throw LiveFailure.malformedResponse }
        return kind
    }

    static func retryAfter(_ header: String?, now: Date) -> Date? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = !value.isEmpty && value.utf8.allSatisfy { (48 ... 57).contains($0) }
        if numeric, let seconds = Double(value), seconds.isFinite, (now.timeIntervalSince1970 + seconds).isFinite {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.isLenient = false
        return formatter.date(from: value)
    }
}
