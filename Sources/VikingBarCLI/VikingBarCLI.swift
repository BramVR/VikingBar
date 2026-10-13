import Foundation
import VikingBarCore

@main
struct VikingBarCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "session" {
            await self.sessionLoop(arguments: Array(arguments.dropFirst()))
            return
        }
        if arguments.first == "fixture-accounts" {
            await self.fixtureAccounts(arguments: Array(arguments.dropFirst()))
            return
        }
        if arguments.first == "accounts" {
            self.accounts(arguments: Array(arguments.dropFirst()))
            return
        }
        if arguments.first == "connect" {
            await self.connect(arguments: arguments)
            return
        }
        if arguments.first == "live" {
            await self.live(arguments: arguments)
            return
        }
        if arguments.first == "proof" {
            await self.proof(arguments: arguments)
            return
        }
        do {
            let options = try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(LaunchOptions.usage)
                print(self.liveUsage)
                return
            }
            let report = try FixtureReport(options: options, referenceDate: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\(LaunchOptions.usage)\n".utf8))
            exit(2)
        }
    }

    private static func proof(arguments: [String]) async {
        if await self.sessionRecoveryProof(arguments: arguments) {
            return
        }
        if arguments.count >= 2, arguments[1] == "telenet-home-api" {
            await self.telenetHomeProof(arguments: Array(arguments.dropFirst(2)))
            return
        }
        if arguments == ["proof", "history-api"] {
            await self.historyProof()
            return
        }
        if arguments == ["proof", "invoices"] {
            await self.invoiceProof()
            return
        }
        if arguments == ["proof", "payment-evidence"] {
            await self.paymentEvidenceProof()
            return
        }
        if arguments == ["proof", "points-api"] {
            await self.pointsProof()
            return
        }
        if arguments.count >= 2, arguments[1] == "balance-api" {
            await self.balanceProof(arguments: Array(arguments.dropFirst(2)))
            return
        }
        guard arguments == ["proof", "auth-balance"] else {
            self.writeProof(ProofReceipt(failure: .invalidInput))
            exit(2)
        }
        let credentials: ProofCredentials
        do {
            credentials = try self.readCredentials()
        } catch {
            self.writeProof(ProofReceipt(failure: .invalidInput))
            exit(2)
        }
        let receipt = await AuthBalanceProof(transport: EphemeralProofTransport()).run(credentials: credentials)
        self.writeProof(receipt)
        if !receipt.passed {
            exit(1)
        }
    }

    private static func sessionRecoveryProof(arguments: [String]) async -> Bool {
        let checks = ["mobile-session-recovery", "mobile-remembered-sign-in", "telenet-remembered-sign-in"]
        if arguments.count == 2, checks.contains(arguments[1]) {
            do {
                let input = try self.readConnectionInput()
                guard input.count <= 32768 else { throw ProofFailure.invalidInput }
                let receipt = try await SessionRecoveryProof.run(check: arguments[1], credentials: input)
                self.writeJSON(receipt)
                if !receipt.passed {
                    exit(1)
                }
            } catch {
                self.writeJSON(CommandFailure(error: "invalid-session-recovery-proof"))
                exit(2)
            }
            return true
        }
        return false
    }

    private static func writeProof(_ receipt: ProofReceipt) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipt) else { exit(2) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
