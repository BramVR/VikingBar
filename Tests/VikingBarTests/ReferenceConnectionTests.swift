import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct ReferenceConnectionTests {
    @Test func `reference connector forwards explicit consent and the expected account fence`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import json, pathlib, sys
        pathlib.Path(__file__ + '.arguments').write_text(json.dumps(sys.argv[1:]))
        print(json.dumps({'schema_version': 1, 'check': 'connect', 'passed': True, 'connected': True,
                          'connection_sha256': '7ac1b8d7010bb6cd3a3e84e7f90136b880bbc899e428ece49333372911ab9052'}))
        """)
        defer { fixture.cleanup() }
        let connection = try ConnectionID(rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010")))
        let expected = AccountMutationFence(revision: 7, connectionID: connection)
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable,
                                         account: FixtureAccounts.telenet)
        try await connector.connect(input: .reference(fixture.executable, rememberPassword: true, expected: expected),
                                    resultURL: nil)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf:
            URL(fileURLWithPath: fixture.executable.path + ".arguments")))
        let index = try #require(arguments.firstIndex(of: "--connection-options"))
        let options = try #require(JSONSerialization
            .jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any])
        #expect(options["remember_password"] as? Bool == true)
        let decoded = try JSONDecoder().decode(AccountMutationFence.self,
                                               from: JSONSerialization
                                                   .data(withJSONObject: #require(options["expected_fence"])))
        #expect(decoded == expected)
        let accountIndex = try #require(arguments.firstIndex(of: "--account"))
        #expect(arguments[accountIndex + 1] == FixtureAccounts.telenet.id)
    }

    @MainActor @Test func `direct submission includes consent and fence without retaining the password`() throws {
        let fields = ConnectionFormModel(account: .init(clientID: "public", username: "reader"))
        fields.password = "synthetic"
        fields.rememberPassword = true
        let fence = AccountMutationFence(revision: 4, connectionID: nil)
        let credentials = try #require(fields.takeCredentials(isFixture: false, expected: fence))
        let request = try AccountConnectionRequest.decode(credentials.takePayload(), for: .mobileVikings)
        #expect(request.rememberPassword)
        #expect(request.expected == fence)
        #expect(fields.password == "")
        guard case let .mobileVikings(value) = request.credentials else { Issue.record("Wrong provider"); return }
        #expect(value.username == "reader")
        #expect(value.password == "synthetic")
    }
}
