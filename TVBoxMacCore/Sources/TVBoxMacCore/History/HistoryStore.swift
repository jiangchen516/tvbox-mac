// HistoryStore.swift — 历史记录 / 收藏持久化
import Foundation

public struct HistoryRecord: Codable, Sendable, Identifiable {
    public var site: String            // 站点 key
    public var vodId: Int
    public var vodIdString: String?
    public var vodName: String
    public var vodPic: String?
    public var episodeTitle: String
    public var episodeGroup: String
    public var position: Double        // 秒
    public var timestamp: Date

    public var id: String { "\(site)#\(vodIdString ?? String(vodId))#\(episodeGroup)#\(episodeTitle)" }

    public init(site: String, vodId: Int, vodIdString: String? = nil, vodName: String,
                vodPic: String? = nil, episodeTitle: String, episodeGroup: String,
                position: Double, timestamp: Date = .now) {
        self.site = site
        self.vodId = vodId
        self.vodIdString = vodIdString
        self.vodName = vodName
        self.vodPic = vodPic
        self.episodeTitle = episodeTitle
        self.episodeGroup = episodeGroup
        self.position = position
        self.timestamp = timestamp
    }
}

public struct Favorite: Codable, Sendable, Identifiable, Hashable {
    public var site: String
    public var vodId: Int
    public var vodName: String
    public var vodPic: String?
    public var addedAt: Date

    public var id: String { "\(site)#\(vodId)" }

    public init(site: String, vodId: Int, vodName: String, vodPic: String? = nil, addedAt: Date = .now) {
        self.site = site
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.addedAt = addedAt
    }
}

public actor HistoryStore {
    private let historyFile: URL
    private let favoritesFile: URL
    private let maxHistory: Int

    public init(directory: URL? = nil, maxHistory: Int = 200) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.historyFile = dir.appendingPathComponent("history.json")
        self.favoritesFile = dir.appendingPathComponent("favorites.json")
        self.maxHistory = maxHistory
    }

    // MARK: - 历史
    public func addHistory(_ record: HistoryRecord) {
        var list = readHistory()
        list.removeAll { $0.id == record.id }
        list.insert(record, at: 0)
        if list.count > maxHistory {
            list = Array(list.prefix(maxHistory))
        }
        try? writeHistory(list)
    }

    public func recent(limit: Int = 50) -> [HistoryRecord] {
        Array(readHistory().prefix(limit))
    }

    /// 某 vod 的断点续播位置
    public func positionFor(site: String, vodId: Int) -> (episodeTitle: String, episodeGroup: String, position: Double)? {
        positionFor(site: site, vodId: String(vodId))
    }

    public func positionFor(site: String, vodId: String) -> (episodeTitle: String, episodeGroup: String, position: Double)? {
        guard let r = readHistory().first(where: {
            $0.site == site && ($0.vodIdString ?? String($0.vodId)) == vodId
        }) else { return nil }
        return (r.episodeTitle, r.episodeGroup, r.position)
    }

    public func updateHistoryMetadata(id: String, vodPic: String?, vodIdString: String?) {
        var list = readHistory()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        if let vodPic, !vodPic.isEmpty { list[index].vodPic = vodPic }
        if let vodIdString, !vodIdString.isEmpty { list[index].vodIdString = vodIdString }
        try? writeHistory(list)
    }

    public func deleteHistory(id: String) {
        var list = readHistory()
        list.removeAll { $0.id == id }
        try? writeHistory(list)
    }

    public func clearHistory() {
        try? writeHistory([])
    }

    private func readHistory() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        return (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
    }

    private func writeHistory(_ list: [HistoryRecord]) throws {
        let data = try JSONEncoder().encode(list)
        try data.write(to: historyFile, options: .atomic)
    }

    // MARK: - 收藏
    public func addFavorite(_ fav: Favorite) {
        var list = readFavorites()
        list.removeAll { $0.id == fav.id }
        list.insert(fav, at: 0)
        try? writeFavorites(list)
    }

    public func removeFavorite(id: String) {
        var list = readFavorites()
        list.removeAll { $0.id == id }
        try? writeFavorites(list)
    }

    public func isFavorite(id: String) -> Bool {
        readFavorites().contains { $0.id == id }
    }

    public func favorites() -> [Favorite] {
        readFavorites()
    }

    private func readFavorites() -> [Favorite] {
        guard let data = try? Data(contentsOf: favoritesFile) else { return [] }
        return (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
    }

    private func writeFavorites(_ list: [Favorite]) throws {
        let data = try JSONEncoder().encode(list)
        try data.write(to: favoritesFile, options: .atomic)
    }
}
