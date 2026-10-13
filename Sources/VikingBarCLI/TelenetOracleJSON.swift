import Foundation

enum TelenetOracleJSON {
    static func object(from data: Data) throws -> [String: Any] {
        try JSONDecoder().decode([String: Value].self, from: data).mapValues(\.rawValue)
    }

    private struct Value: Decodable {
        let rawValue: Any

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self.rawValue = NSNull()
            } else if let object = try? container.decode([String: Self].self) {
                self.rawValue = object.mapValues(\.rawValue)
            } else if let array = try? container.decode([Self].self) {
                self.rawValue = array.map(\.rawValue)
            } else if let string = try? container.decode(String.self) {
                self.rawValue = string
            } else if let boolean = try? container.decode(Bool.self) {
                self.rawValue = boolean
            } else {
                // JSONSerialization's Double bridge rounds some provider fractions before comparison.
                self.rawValue = try NSDecimalNumber(decimal: container.decode(Decimal.self))
            }
        }
    }
}
