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
        var dataDisplayMode: DataDisplayMode
        var refreshInterval: RefreshInterval

        init(showRemainingGB: Bool, dataDisplayMode: DataDisplayMode, refreshInterval: RefreshInterval) {
            self.showRemainingGB = showRemainingGB
            self.dataDisplayMode = dataDisplayMode
            self.refreshInterval = refreshInterval
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.showRemainingGB = try values.decodeIfPresent(Bool.self, forKey: .showRemainingGB) ?? false
            self.dataDisplayMode = try values.decodeIfPresent(DataDisplayMode.self, forKey: .dataDisplayMode)
                ?? .remaining
            self.refreshInterval = try values.decodeIfPresent(RefreshInterval.self, forKey: .refreshInterval)
                ?? .fiveMinutes
        }
    }

    private let fileURL: URL?
    private let fileIO: any MenuBarPreferenceIO
    public private(set) var showRemainingGB = false
    public private(set) var dataDisplayMode: DataDisplayMode = .remaining
    public private(set) var refreshInterval: RefreshInterval = .fiveMinutes
    public private(set) var errorMessage: String?

    public init(fileURL: URL?, fileIO: any MenuBarPreferenceIO = FileMenuBarPreferenceIO()) {
        self.fileURL = fileURL
        self.fileIO = fileIO
        guard let fileURL else { return }
        do {
            if let data = try fileIO.read(from: fileURL) {
                let contents = try JSONDecoder().decode(Contents.self, from: data)
                self.showRemainingGB = contents.showRemainingGB
                self.dataDisplayMode = contents.dataDisplayMode
                self.refreshInterval = contents.refreshInterval
            }
        } catch {
            self.errorMessage = "Could not load menu bar setting: \(error.localizedDescription)"
        }
    }

    public func setShowRemainingGB(_ value: Bool) {
        self.showRemainingGB = value
        self.save()
    }

    public func setDataDisplayMode(_ value: DataDisplayMode) {
        self.dataDisplayMode = value
        self.save()
    }

    public func setRefreshInterval(_ value: RefreshInterval) {
        self.refreshInterval = value
        self.save()
    }

    private func save() {
        do {
            if let fileURL = self.fileURL {
                try self.fileIO.write(JSONEncoder().encode(Contents(
                    showRemainingGB: self.showRemainingGB, dataDisplayMode: self.dataDisplayMode,
                    refreshInterval: self.refreshInterval,
                )), to: fileURL)
            }
            self.errorMessage = nil
        } catch {
            self.errorMessage = "Menu bar setting changed for this session but could not be saved: "
                + error.localizedDescription
        }
    }
}
