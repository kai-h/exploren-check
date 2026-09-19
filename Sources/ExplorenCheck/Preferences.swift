import Foundation

struct WatchEntry: Codable, Sendable, Equatable {
    /// Internal location id. Not printed on the charger; see Models.swift.
    var locationId: Int
    /// Numbers as printed on the chargers. Empty means every EVSE there.
    var identifiers: [String]
}

struct Preferences: Codable, Sendable, Equatable {
    var watch: [WatchEntry]
    var pollSeconds: Int
    /// Battery level at which an occupied charger counts as nearly free.
    /// Optional so that a plist written before this existed still decodes;
    /// a missing required key would fail the decode and silently replace the
    /// whole watchlist with the defaults.
    var nearlyFreePercent: Int?

    /// Polling any harder than this is pointless as well as rude: the event
    /// stream already delivers changes as they happen, and the poll is only a
    /// backstop against a connection that has died quietly. Enforced here
    /// rather than only in the UI, so a hand-edited file cannot go below it.
    static let minimumPollSeconds = 60
    static let maximumPollSeconds = 900

    var pollInterval: Int {
        min(Self.maximumPollSeconds, max(Self.minimumPollSeconds, pollSeconds))
    }

    var nearlyFreeThreshold: Int { nearlyFreePercent ?? 95 }

    /// No chargers to begin with. The app opens on an empty state that sends
    /// you to the picker, rather than shipping with someone else's chargers
    /// in it.
    static let `default` = Preferences(
        watch: [],
        pollSeconds: 60,
        nearlyFreePercent: 95
    )

    static var fileURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ExplorenCheck/preferences.plist")
    }

    /// Reads the plist, writing the defaults out first if it isn't there yet,
    /// so there is always a file to hand-edit.
    static func load() -> Preferences {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else {
            try? Preferences.default.write()
            return .default
        }
        guard let prefs = try? PropertyListDecoder().decode(Preferences.self, from: data) else {
            return .default
        }
        return prefs
    }

    func write() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: url)
    }
}
