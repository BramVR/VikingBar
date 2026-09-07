import Foundation

public enum SessionDateCoding {
    public static var encodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try value.encode(formatter.string(from: date))
        }
    }

    public static var decodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid session date")
            }
            return date
        }
    }
}
