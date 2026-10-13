import CryptoKit
import Foundation
import VikingBarCore

struct SessionRecoveryReceipt: Encodable, Sendable {
    let schemaVersion = 1
    let check: String
    let phase: String
    let accountSHA256: String
    var connectionSHA256: String?
    var originalConnectionSHA256: String?
    var passed = false
    var bootstrap = false
    var owned = false
    var savedSignIn = false
    var serviceRetained = false
    var remembered = false
    var restored = false
    var loss = "unobserved"
    var recovered = false
    var usage = false
    var disabled = false
    var loggedOut = false
    var passwordGrants = 0
    var refreshGrants = 0
    var failure = "none"

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case accountSHA256 = "account_sha256"
        case connectionSHA256 = "connection_sha256"
        case originalConnectionSHA256 = "original_connection_sha256"
        case passwordGrants = "password_grants"
        case refreshGrants = "refresh_grants"
        case check, phase, passed, bootstrap, owned, savedSignIn, serviceRetained, remembered, restored, loss,
             recovered,
             usage, disabled, loggedOut, failure
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

actor MobileRecoveryTransport: ProofHTTPTransport {
    let base: any ProofHTTPTransport
    let deadline: Date
    let delayAccess: Bool
    var expiry: Date?
    var delayed = false
    var passwordGrants = 0
    var refreshGrants = 0
    var rejectedAccess = false
    var rejectedGrant = false

    init(deadline: Date, delayAccess: Bool, base: any ProofHTTPTransport = EphemeralProofTransport()) {
        self.deadline = deadline
        self.delayAccess = delayAccess
        self.base = base
    }

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        if self.delayAccess, !self.delayed, request.httpMethod == "GET" {
            guard let expiry = self.expiry, expiry < self.deadline else { throw LiveFailure.rateLimited }
            self.delayed = true
            try await SessionRecoveryProof.wait(until: expiry.addingTimeInterval(2), deadline: self.deadline)
        }
        guard Date() < self.deadline else { throw LiveFailure.rateLimited }
        let response = try await self.base.send(request)
        if request.httpMethod == "GET", response.statusCode == 401 {
            self.rejectedAccess = true
        }
        if request.url?.path == "/mv/oauth2/token" {
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let password = form.contains("grant_type=password")
            if password {
                self.passwordGrants += 1
            } else {
                self.refreshGrants += 1
            }
            if let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
                if response.statusCode == 200, let seconds = object["expires_in"] as? Int, seconds > 0 {
                    self.expiry = Date().addingTimeInterval(TimeInterval(seconds))
                }
                if !password, response.statusCode == 400, object["error"] as? String == "invalid_grant" {
                    self.rejectedGrant = true
                }
            }
        }
        return response
    }
}

private actor HomeRecoveryTransport: TelenetTransport {
    let base: any TelenetTransport = EphemeralTelenetTransport()
    var rejectedSession = false
    var passwordGrants = 0
    func send(_ request: URLRequest) async throws -> TelenetResponse {
        if request.httpMethod == "POST", request.url?.path == "/idp/idx/challenge/answer" {
            self.passwordGrants += 1
        }
        let response = try await self.base.send(request)
        let authenticated = request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Cookie") != nil
        if authenticated, [401, 403].contains(response.status) {
            self.rejectedSession = true
        }
        return response
    }
}

private struct RecoveryContext {
    let check: String
    let input: RecoveryInput
    let deadline: Date
    let mobile: MobileRecoveryTransport
    let home = HomeRecoveryTransport()
    let session: any ProviderAccountSession
    let viking: VikingSession?

    init(check: String, input: RecoveryInput) throws {
        self.check = check
        self.input = input
        self.deadline = Date().addingTimeInterval(input.timeout)
        self.mobile = MobileRecoveryTransport(deadline: self.deadline, delayAccess: check == "mobile-session-recovery")
        if input.key.provider == .mobileVikings {
            let actor = try VikingSession.production(storage: input.storage, transport: self.mobile,
                                                     allowInteraction: false)
            self.viking = actor
            self.session = MobileVikingsAccount(key: input.key, session: actor)
        } else {
            self.viking = nil
            self.session = try TelenetHomeAccount.production(storage: input.storage, transport: self.home,
                                                             allowInteraction: false)
        }
    }

    var sessionStore: KeychainSessionStore {
        KeychainSessionStore(account: self.input.storage.keychainAccount,
                             service: self.input.key.provider == .telenet
                                 ? "be.bram.vikingbar.telenet.session" : "be.bram.vikingbar.oauth",
                             allowInteraction: false)
    }

    var rememberedStore: KeychainSessionStore {
        KeychainSessionStore(account: self.input.storage.keychainAccount,
                             service: "be.bram.vikingbar.remembered-sign-in", allowInteraction: false)
    }

    func perform(_ receipt: inout SessionRecoveryReceipt) async throws {
        if ["exercise", "prepare"].contains(self.input.phase) {
            do {
                let handle = try FileSessionLease(url: self.input.storage.leaseURL).acquire()
                defer { handle.release() }
                guard try self.sessionStore.load() == nil, try self.rememberedStore.load() == nil else {
                    throw LiveFailure.storage
                }
                if self.input.phase == "prepare" {
                    try self.input.publishOwnership()
                }
            }
            receipt.owned = true
            if self.input.phase == "prepare" {
                receipt.passed = true
            } else if let credentials = self.input.credentials {
                try await self.exercise(credentials, receipt: &receipt)
            }
            return
        }
        try await self.inspectOrMutate(&receipt)
    }

    private func inspectOrMutate(_ receipt: inout SessionRecoveryReceipt) async throws {
        do { try await self.session.perform(.restore) } catch {
            if self.input.phase != "logout" {
                throw error
            }
        }
        guard let fence = await self.session.state().signIn?.fence else { throw LiveFailure.storage }
        switch self.input.phase {
        case "disable": try await self.session.perform(.disableRememberedSignIn(fence))
        case "logout": try await self.session.perform(.logout(fence))
        default: break
        }
        let result = await self.session.state()
        receipt.restored = true
        receipt.remembered = result.signIn?.remembered == .available
        receipt.disabled = try result.signIn?.remembered == .disabled && (self.rememberedStore.load()) == nil
        receipt.loggedOut = try result.connectionID == nil && receipt.disabled && (self.sessionStore.load()) == nil
        receipt.usage = SessionRecoveryProof.hasUsage(result)
        switch self.input.phase {
        case "disable": receipt.passed = receipt.disabled && !receipt.loggedOut
        case "logout": receipt.passed = receipt.loggedOut
        default: receipt.passed = true
        }
    }

    private func exercise(_ credentials: ProviderCredentials, receipt: inout SessionRecoveryReceipt) async throws {
        let remember = self.check != "mobile-session-recovery"
        let original = try await self.session.connect(
            credentials: credentials,
            rememberPassword: remember,
            expected: nil,
        )
        receipt.bootstrap = true
        receipt.originalConnectionSHA256 = SessionRecoveryReceipt.digest(original.rawValue.uuidString.lowercased())
        receipt.remembered = await self.session.state().signIn?.remembered == .available
        guard !remember || receipt.remembered else { throw LiveFailure.storage }
        try await self.session.perform(.restore)
        receipt.restored = await self.session.state().connectionID == original
        if self.check == "mobile-session-recovery" {
            try await self.session.perform(.refresh)
            receipt.loss = await self.mobile.rejectedAccess ? "access-rejected" : "unobserved"
            let state = await self.session.state()
            receipt.usage = SessionRecoveryProof.hasUsage(state)
            receipt.recovered = receipt.loss == "access-rejected" && state.connectionID == original
                && receipt.usage && state.failure == nil
        } else if let viking = self.viking {
            try await self.mobileSavedSignIn(viking, original: original, receipt: &receipt)
        } else {
            try await self.homeSavedSignIn(original, receipt: &receipt)
        }
        receipt.passed = receipt.bootstrap && receipt.restored && receipt.recovered && receipt.usage
            && receipt.failure == "none"
    }

    private var observationDeadline: Date {
        self.deadline.addingTimeInterval(-min(120, self.input.timeout / 2))
    }

    private func mobileSavedSignIn(
        _ viking: VikingSession, original: ConnectionID, receipt: inout SessionRecoveryReceipt,
    ) async throws {
        _ = try await viking.refresh()
        let selected = await viking.state().selectedSubscriptionID
        let expiry = await self.mobile.expiry ?? self.deadline
        if expiry.addingTimeInterval(2) < self.observationDeadline {
            try await SessionRecoveryProof.wait(until: expiry.addingTimeInterval(2), deadline: self.observationDeadline)
            do { _ = try await viking.refresh(forceTokenRefresh: true) } catch {
                guard await self.mobile.rejectedGrant else { throw error }
            }
        } else {
            try await SessionRecoveryProof.wait(until: self.observationDeadline, deadline: self.deadline)
        }
        receipt.loss = await self.mobile.rejectedGrant ? "grant-rejected" : "unobserved"
        if receipt.loss == "unobserved" {
            receipt.failure = "provider-session-loss-unobserved"
        }
        let recovery = try VikingSession.production(storage: self.input.storage, transport: self.mobile,
                                                    allowInteraction: false)
        _ = try? await recovery.restore()
        let state = await recovery.state()
        receipt.restored = state.connectionID == original && state.signIn?.remembered == .available
        guard receipt.restored, let fence = state.signIn?.fence else { throw LiveFailure.storage }
        try await self.waitForPassword(state)
        _ = try await recovery.savedSignIn(expected: fence)
        receipt.savedSignIn = true
        let recovered = await recovery.state()
        receipt.serviceRetained = selected != nil && recovered.selectedSubscriptionID == selected
        self.recordRecovered(recovered, original: original, receipt: &receipt)
    }

    private func observeHomeLoss() async throws {
        while Date() < self.observationDeadline, await !(self.home.rejectedSession) {
            let state = await self.session.state()
            let next = max(state.nextRefreshAt ?? Date().addingTimeInterval(3600), Date().addingTimeInterval(60))
            if next >= self.observationDeadline {
                try await SessionRecoveryProof.wait(until: self.observationDeadline, deadline: self.deadline)
                return
            }
            try await SessionRecoveryProof.wait(until: next, deadline: self.observationDeadline)
            do { try await self.session.perform(.refresh) } catch {
                guard await self.home.rejectedSession else { throw error }
            }
        }
    }

    private func homeSavedSignIn(_ original: ConnectionID, receipt: inout SessionRecoveryReceipt) async throws {
        let originalService = await self.session.state().account?.selectedService
        try await self.observeHomeLoss()
        receipt.loss = await self.home.rejectedSession ? "unclassified-cookie-loss" : "unobserved"
        receipt.failure = "natural-expiry-unverified"
        let restored = try TelenetHomeAccount.production(storage: self.input.storage, transport: self.home,
                                                         allowInteraction: false)
        do { try await restored.perform(.restore) } catch {
            guard await self.home.rejectedSession else { throw error }
        }
        let state = await restored.state()
        receipt.restored = state.connectionID == original && state.signIn?.remembered == .available
        guard receipt.restored, let fence = state.signIn?.fence else { throw LiveFailure.storage }
        try await self.waitForPassword(state)
        try await restored.perform(.savedSignIn(fence))
        receipt.savedSignIn = true
        let recovered = await restored.state()
        receipt.serviceRetained = originalService != nil && recovered.account?.selectedService == originalService
        self.recordRecovered(recovered, original: original, receipt: &receipt)
    }

    private func waitForPassword(_ state: LiveSessionState) async throws {
        if let next = state.signIn?.nextPasswordAttemptAt {
            try await SessionRecoveryProof.wait(until: next, deadline: self.deadline)
        }
    }

    private func recordRecovered(
        _ state: LiveSessionState, original: ConnectionID, receipt: inout SessionRecoveryReceipt,
    ) {
        receipt.usage = SessionRecoveryProof.hasUsage(state)
        receipt.recovered = state.connectionID != original && state.connectionID != nil
            && receipt.usage && receipt.serviceRetained && state.failure == nil
        receipt.connectionSHA256 = state.connectionID.map {
            SessionRecoveryReceipt.digest($0.rawValue.uuidString.lowercased())
        }
    }
}

enum SessionRecoveryProof {
    static func run(check: String, credentials: Data) async throws -> SessionRecoveryReceipt {
        let input = try RecoveryInput(check: check, data: credentials)
        let context = try RecoveryContext(check: check, input: input)
        var receipt = SessionRecoveryReceipt(check: check, phase: input.phase,
                                             accountSHA256: SessionRecoveryReceipt.digest(input.key.id))
        do { try await context.perform(&receipt) } catch {
            receipt.failure = Date() >= context.deadline ? "observation-timeout" : "operation-failed"
        }
        if receipt.connectionSHA256 == nil {
            receipt.connectionSHA256 = await context.session.state().connectionID.map {
                SessionRecoveryReceipt.digest($0.rawValue.uuidString.lowercased())
            }
        }
        receipt.passwordGrants = input.key.provider == .telenet
            ? await context.home.passwordGrants : await context.mobile.passwordGrants
        receipt.refreshGrants = await context.mobile.refreshGrants
        if !receipt.passed, receipt.failure == "none" {
            receipt.failure = "required-stage-unobserved"
        }
        return receipt
    }

    static func wait(until target: Date, deadline: Date) async throws {
        while Date() < target {
            guard Date() < deadline else { throw LiveFailure.rateLimited }
            let seconds = min(30, min(target.timeIntervalSinceNow, deadline.timeIntervalSinceNow))
            try await Task.sleep(for: .seconds(max(0.01, seconds)))
        }
    }

    static func hasUsage(_ state: LiveSessionState) -> Bool {
        guard case .current = state.snapshot.freshness else { return false }
        return state.failure == nil && state.snapshot.allowance != .unavailable
    }
}
