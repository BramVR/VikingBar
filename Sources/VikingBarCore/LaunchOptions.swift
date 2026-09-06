import Foundation

public struct LaunchOptions: Equatable, Sendable {
    public let fixture: FixtureState?
    public let unit: DataUnit
    public let timeZone: TimeZone
    public let showHelp: Bool

    public static let usage = """
    Usage: vikingbar --fixture STATE [--unit GB|GiB] [--time-zone IANA]
    States: finite, unlimited, exhausted, stale, error
    Prints synthetic snapshot and shared menu presentation as JSON. No account access.
    """

    public init(arguments: [String], defaultTimeZone: TimeZone = .current) throws {
        var fixture: FixtureState?
        var unit = DataUnit.gigabytes
        var timeZone = defaultTimeZone
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                guard arguments.count == 1 else { throw ArgumentError.invalid("Use --help on its own.") }
                self.fixture = nil
                self.unit = unit
                self.timeZone = timeZone
                self.showHelp = true
                return
            }
            guard ["--fixture", "--unit", "--time-zone"].contains(argument),
                  seen.insert(argument).inserted,
                  index + 1 < arguments.count
            else { throw ArgumentError.invalid("Unknown, repeated, or incomplete argument: \(argument)") }
            let value = arguments[index + 1]
            switch argument {
            case "--fixture":
                guard let parsed = FixtureState(rawValue: value) else {
                    throw ArgumentError.invalid("Unknown fixture: \(value)")
                }
                fixture = parsed
            case "--unit":
                guard let parsed = DataUnit(rawValue: value) else {
                    throw ArgumentError.invalid("Unknown unit: \(value). Use GB or GiB.")
                }
                unit = parsed
            default:
                guard let parsed = TimeZone(identifier: value) else {
                    throw ArgumentError.invalid("Unknown time zone: \(value)")
                }
                timeZone = parsed
            }
            index += 2
        }
        self.fixture = fixture
        self.unit = unit
        self.timeZone = timeZone
        self.showHelp = false
    }
}

public enum ArgumentError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case fixtureRequired

    public var description: String {
        switch self {
        case let .invalid(message): message
        case .fixtureRequired: "Live account access is not available. Choose an explicit --fixture STATE."
        }
    }
}

public struct FixtureReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let snapshot: UsageSnapshot
    public let menu: MenuPresentation

    public init(options: LaunchOptions, referenceDate: Date) throws {
        guard let fixture = options.fixture else { throw ArgumentError.fixtureRequired }
        self.schemaVersion = 1
        self.snapshot = fixture.snapshot(referenceDate: referenceDate)
        self.menu = MenuPresentation(snapshot: self.snapshot, unit: options.unit, timeZone: options.timeZone)
    }
}
