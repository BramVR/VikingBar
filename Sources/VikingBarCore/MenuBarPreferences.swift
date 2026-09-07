import Foundation

public protocol MenuBarPreferenceIO {
    func read(from url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
}

public struct FileMenuBarPreferenceIO: MenuBarPreferenceIO {
    public init() {}

    public func read(from url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    public func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public final class MenuBarPreferences {
    private struct Contents: Codable {
        var showRemainingGB: Bool

        init(showRemainingGB: Bool) {
            self.showRemainingGB = showRemainingGB
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.showRemainingGB = try values.decodeIfPresent(Bool.self, forKey: .showRemainingGB) ?? false
        }
    }

    private let fileURL: URL?
    private let fileIO: any MenuBarPreferenceIO
    public private(set) var showRemainingGB = false
    public private(set) var errorMessage: String?

    public init(fileURL: URL?, fileIO: any MenuBarPreferenceIO = FileMenuBarPreferenceIO()) {
        self.fileURL = fileURL
        self.fileIO = fileIO
        guard let fileURL else { return }
        do {
            if let data = try fileIO.read(from: fileURL) {
                self.showRemainingGB = try JSONDecoder().decode(Contents.self, from: data).showRemainingGB
            }
        } catch {
            self.errorMessage = "Could not load menu bar setting: \(error.localizedDescription)"
        }
    }

    public func setShowRemainingGB(_ value: Bool) {
        self.showRemainingGB = value
        do {
            if let fileURL = self.fileURL {
                try self.fileIO.write(JSONEncoder().encode(Contents(showRemainingGB: value)), to: fileURL)
            }
            self.errorMessage = nil
        } catch {
            self.errorMessage = "Menu bar setting changed for this session but could not be saved: "
                + error.localizedDescription
        }
    }
}
