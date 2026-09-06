import Foundation
import VikingBarCore

@main
struct VikingBarCLI {
    static func main() {
        do {
            let options = try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(LaunchOptions.usage)
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
}
