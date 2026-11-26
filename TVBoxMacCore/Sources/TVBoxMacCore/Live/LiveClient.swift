// LiveClient.swift — 拉取直播源播放列表（带 TTL 内存缓存）
import Foundation

/// 直播频道列表加载器。抓取/解析逻辑放这里，UI 只负责展示；
/// HTTP 可注入，便于单测（不联网）。
public actor LiveClient {
    private struct CacheEntry {
        let genres: [LiveGenre]
        let storedAt: Date
    }

    private let http: HTTPFetching
    private let cacheTTL: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    /// 网络失败时的磁盘兜底（同一 URL 的最近一次成功结果）
    private let diskCacheDirectory: URL
    private let diskMaxAge: TimeInterval

    /// - Parameters:
    ///   - http: 抓取实现（默认 URLSession）
    ///   - cacheTTL: 同一播放列表地址的缓存有效期（秒）；默认 5 分钟
    public init(http: HTTPFetching = HttpClient(), cacheTTL: TimeInterval = 300,
                diskCacheDirectory: URL? = nil,
                diskMaxAge: TimeInterval = 7 * 24 * 3600) {
        self.http = http
        self.cacheTTL = cacheTTL
        self.diskCacheDirectory = diskCacheDirectory ?? Self.defaultDiskDirectory()
        self.diskMaxAge = diskMaxAge
    }

    /// 拉取并解析频道列表。命中缓存时不再请求网络（forceReload 强制刷新）。
    public func load(_ source: LiveSource, forceReload: Bool = false) async throws -> [LiveGenre] {
        // 配置里内联的频道列表：不需要网络，直接按分组返回
        if source.hasInlineChannels {
            let genres = LiveParser.group(source.inlineChannels)
            guard !genres.isEmpty else { throw LiveError.noChannels(source.name) }
            return genres
        }
        guard source.isHTTPPlaylist, let url = URL(string: source.url) else {
            throw LiveError.unsupportedSource(source.name)
        }
        if !forceReload,
           let cached = cache[source.url],
           Date().timeIntervalSince(cached.storedAt) < cacheTTL {
            return cached.genres
        }

        let data: Data
        do {
            (data, _) = try await http.get(url, headers: source.requestHeaders)
        } catch {
            if let cached = Self.readDiskCache(url: source.url,
                                               directory: diskCacheDirectory,
                                               maxAge: diskMaxAge) {
                PlayerLog.append("📺 直播源「\(source.name)」网络失败，使用磁盘缓存（\(cached.count) 个分组）")
                return cached
            }
            throw LiveError.requestFailed(source.name, error.localizedDescription)
        }

        guard let text = LiveTextDecoder.playlistText(from: data) else {
            throw LiveError.undecodable(source.name)
        }
        let genres = LiveParser.parse(text)
        guard !genres.isEmpty else {
            throw LiveError.noChannels(source.name)
        }
        cache[source.url] = CacheEntry(genres: genres, storedAt: .now)
        Self.writeDiskCache(url: source.url, genres: genres, directory: diskCacheDirectory)
        return genres
    }

    // MARK: - 磁盘缓存

    private static func defaultDiskDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMac/LiveCache", isDirectory: true)
    }

    private static func diskFile(for url: String, directory: URL) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return directory.appendingPathComponent("\(hex).json")
    }

    private struct DiskEntry: Codable {
        let storedAt: Date
        let genres: [LiveGenre]
    }

    private static func writeDiskCache(url: String, genres: [LiveGenre], directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(DiskEntry(storedAt: .now, genres: genres))
            try data.write(to: diskFile(for: url, directory: directory), options: .atomic)
        } catch {
            PlayerLog.append("📺 直播源磁盘缓存写入失败: \(error.localizedDescription)")
        }
    }

    private static func readDiskCache(url: String, directory: URL, maxAge: TimeInterval) -> [LiveGenre]? {
        let file = diskFile(for: url, directory: directory)
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(DiskEntry.self, from: data),
              Date().timeIntervalSince(entry.storedAt) <= maxAge,
              !entry.genres.isEmpty else { return nil }
        return entry.genres
    }

    /// 丢弃全部缓存（导入/切换配置后可调用）
    public func clearCache() {
        cache.removeAll()
    }

    /// 标记某个源已缓存（测试/调试用）
    public func isCached(_ source: LiveSource) -> Bool {
        cache[source.url] != nil
    }
}
