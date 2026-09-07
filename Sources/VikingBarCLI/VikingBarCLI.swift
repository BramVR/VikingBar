import Foundation
import VikingBarCore

@main
struct VikingBarCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "session" {
            guard arguments == ["session"] else {
                self.writeJSON(CommandFailure(error: "invalid-session-command"))
                exit(2)
            }
            await self.sessionLoop()
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
        if arguments == ["proof", "points-api"] {
            await self.pointsProof()
            return
        }
        if arguments == ["proof", "balance-api"] {
            await self.balanceProof()
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

    private static func writeProof(_ receipt: ProofReceipt) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipt) else { exit(2) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
