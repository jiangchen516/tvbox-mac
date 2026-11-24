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

    /// - Parameters:
    ///   - http: 抓取实现（默认 URLSession）
    ///   - cacheTTL: 同一播放列表地址的缓存有效期（秒）；默认 5 分钟
    public init(http: HTTPFetching = HttpClient(), cacheTTL: TimeInterval = 300) {
        self.http = http
        self.cacheTTL = cacheTTL
    }

    /// 拉取并解析频道列表。命中缓存时不再请求网络（forceReload 强制刷新）。
    public func load(_ source: LiveSource, forceReload: Bool = false) async throws -> [LiveGenre] {
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
        return genres
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
