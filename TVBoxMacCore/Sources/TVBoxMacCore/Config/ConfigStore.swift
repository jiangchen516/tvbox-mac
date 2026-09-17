// ConfigStore.swift — 用户导入配置列表的持久化
import Foundation

/// 持久化目录可注入，便于测试（默认 App Support/TVBoxMac/）
public actor ConfigStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("configs.json")
    }

    public struct StoredEntry: Codable, Sendable, Identifiable {
        public var loaded: LoadedConfig
        public var addedAt: Date
        public var id: String { loaded.id }
        public init(loaded: LoadedConfig, addedAt: Date = .now) {
            self.loaded = loaded
            self.addedAt = addedAt
        }
    }

    public func load() -> [StoredEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([StoredEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [StoredEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public func add(_ loaded: LoadedConfig) throws -> [StoredEntry] {
        var entries = load()
        // 同 id 覆盖
        entries.removeAll { $0.id == loaded.id }
        entries.append(StoredEntry(loaded: loaded))
        try save(entries)
        return entries
    }

    @discardableResult
    public func remove(id: String) throws -> [StoredEntry] {
        var entries = load()
        entries.removeAll { $0.id == id }
        try save(entries)
        return entries
    }

    @discardableResult
    public func setEnabled(id: String, enabled: Bool) throws -> [StoredEntry] {
        var entries = load()
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].loaded.enabled = enabled
        }
        try save(entries)
        return entries
    }
}
