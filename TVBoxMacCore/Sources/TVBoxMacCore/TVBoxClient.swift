// TVBoxClient.swift — 组合取数层：按 site.type 分发到 CatVodClient / SpiderClient
import Foundation

public actor TVBoxClient {
    private let catVod: CatVodClient
    private let spider: SpiderClient
    private let managedAndroidSpider: ManagedAndroidSpiderClient?
    private var categoryCache: [String: [String]] = [:]
    private var detailCache: [String: Vod] = [:]
    private var browseCache: [BrowseCacheKey: BrowseCacheEntry] = [:]
    private let browseCacheTTL: TimeInterval = 120
    private let maxBrowseCacheEntries = 300

    private struct BrowseCacheKey: Hashable {
        let siteID: String
        let api: String
        let jar: String
        let ext: JSONValue?
        let category: String
        let page: Int
    }

    private struct BrowseCacheEntry {
        let value: VodPage
        let storedAt: Date
    }
    public private(set) var loadedConfigs: [LoadedConfig] = []

    public init(catVod: CatVodClient? = nil, spider: SpiderClient? = nil,
                managedAndroidSpider: ManagedAndroidSpiderClient? = nil) {
        self.catVod = catVod ?? CatVodClient()
        self.spider = spider ?? SpiderClient()
        self.managedAndroidSpider = managedAndroidSpider
    }

    /// 加载配置后同步 parses/header/spider 到两个 client
    /// - Parameter spiderURL: 配置级 spider 地址（已解析为绝对 URL、剥 md5 后缀）；
    ///   传 nil 时退回 config.spider 原文
    public func configure(_ config: TVBoxConfig, spiderURL: String? = nil) async {
        await catVod.setParses(config.parses)
        await spider.setParses(config.parses)
        let h = HeaderParser.parse(config.header)
        await catVod.setGlobalHeader(h)
        await spider.setGlobalHeader(h)
        // 配置级 spider 地址（jar/js），spider 站点用它找实现。
        // 相对路径（"./jar/fan.txt"）必须先解析成绝对 URL，否则 Bridge 下载 jar 失败
        await spider.setGlobalSpiderURL(spiderURL ?? config.spider)
        await managedAndroidSpider?.setGlobalSpiderURL(spiderURL ?? config.spider)
    }

    public func allSites() -> [Site] {
        loadedConfigs.flatMap { $0.config.sites }
    }

    public func loadConfigs(_ configs: [LoadedConfig]) async {
        // 多配置共存：每份配置的 csp_ 站点绑定【该配置自己】解析出的 spider jar。
        // 否则全局 spiderURL 只取第一份配置的，会盖掉其他配置的 jar
        // （实测：摸鱼配置的 qiniu jar 盖掉饭太硬的 fan.txt → Guard 站点全空）
        var resolved = configs
        for i in resolved.indices {
            guard let spiderURL = resolved[i].resolvedGlobalSpiderURL() else { continue }
            for j in resolved[i].config.sites.indices {
                let s = resolved[i].config.sites[j]
                let jarEmpty = s.jar == nil || s.jar?.isEmpty == true
                let isCsp = s.api.lowercased().hasPrefix("csp_")
                if jarEmpty && isCsp {
                    resolved[i].config.sites[j].jar = spiderURL
                }
            }
        }
        loadedConfigs = resolved
        categoryCache.removeAll(keepingCapacity: true)
        detailCache.removeAll(keepingCapacity: true)
        browseCache.removeAll(keepingCapacity: true)
        // 默认用第一份配置的 parses/header
        // 配置级 spider 的相对路径（"./jar/fan.txt"）先按该配置的 URL 解析成绝对 URL
        if let first = resolved.first {
            await configure(first.config, spiderURL: first.resolvedGlobalSpiderURL())
        }
    }

    // MARK: - VodFetching 风格的分发（UI 直接用这些方法）
    private func client(for site: Site) -> any VodFetching {
        if let managedAndroidSpider, site.type == 3 || site.api.lowercased().hasPrefix("csp_") {
            return ManagedAndroidSpiderProxy(spider: managedAndroidSpider, site: site)
        }
        // spider 站点：type 0/3，或 api 为 csp_ 前缀（TVBox 约定：api 是 spider 类名，不是 URL；
        // 实现在 site.jar / 配置级 spider 字段指向的 jar/js 里）。其余走 CatVod。
        if site.type == 0 || site.type == 3 || site.api.lowercased().hasPrefix("csp_") {
            return SpiderProxy(spider: spider, site: site)
        }
        return CatVodProxy(catVod: catVod, site: site)
    }

    public func categories(site: Site) async throws -> [String] {
        if let cached = categoryCache[site.id] {
            return cached
        }
        let result = try await client(for: site).categories(site: site)
        categoryCache[site.id] = result
        return result
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
        let key = BrowseCacheKey(
            siteID: site.id,
            api: site.api,
            jar: site.jar ?? site.spider ?? "",
            ext: site.ext,
            category: category ?? "",
            page: page
        )
        if let cached = browseCache[key], Date().timeIntervalSince(cached.storedAt) < browseCacheTTL {
            PlayerLog.append("⚡ 浏览缓存命中 \(site.name) 分类=\(category ?? "-") 页=\(page)")
            return cached.value
        }
        let result = try await client(for: site).browse(site: site, category: category, page: page)
        browseCache[key] = BrowseCacheEntry(value: result, storedAt: .now)
        if browseCache.count > maxBrowseCacheEntries,
           let oldest = browseCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            browseCache.removeValue(forKey: oldest)
        }
        return result
    }

    /// 用户下拉刷新时丢弃该站点（或当前分类）的分页缓存。
    public func invalidateBrowseCache(site: Site, category: String? = nil) {
        browseCache = browseCache.filter { key, _ in
            guard key.siteID == site.id, key.api == site.api else { return true }
            if let category { return key.category != category }
            return false
        }
    }

    public func search(site: Site, keyword: String, page: Int) async throws -> VodPage {
        try await client(for: site).search(site: site, keyword: keyword, page: page)
    }

    public func detail(site: Site, vodId: String) async throws -> Vod {
        let cacheKey = "\(site.id)#\(vodId)"
        if let cached = detailCache[cacheKey] {
            return cached
        }
        let result = try await client(for: site).detail(site: site, vodId: vodId)
        detailCache[cacheKey] = result
        return result
    }

    public func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String {
        try await client(for: site).resolvePlayUrl(site: site, vod: vod, episode: episode)
    }

    /// 跨站聚合搜索（M5）
    public func aggregateSearch(keyword: String, sites: [Site]?, page: Int = 1) async -> [(site: Site, page: VodPage)] {
        let targets = sites ?? allSites()
        var out: [(Site, VodPage)] = []
        for site in targets where site.searchable == 1 {
            if let p = try? await client(for: site).search(site: site, keyword: keyword, page: page) {
                out.append((site, p))
            }
        }
        return out
    }
}

// 轻量代理：把 actor 方法包成 VodFetching 供 TVBoxClient 统一调用
private struct CatVodProxy: VodFetching {
    let catVod: CatVodClient
    let site: Site
    func categories(site: Site) async throws -> [String] { try await catVod.categories(site: site) }
    func browse(site: Site, category: String?, page: Int) async throws -> VodPage { try await catVod.browse(site: site, category: category, page: page) }
    func search(site: Site, keyword: String, page: Int) async throws -> VodPage { try await catVod.search(site: site, keyword: keyword, page: page) }
    func detail(site: Site, vodId: String) async throws -> Vod { try await catVod.detail(site: site, vodId: vodId) }
    func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String { try await catVod.resolvePlayUrl(site: site, vod: vod, episode: episode) }
}

private struct SpiderProxy: VodFetching {
    let spider: SpiderClient
    let site: Site
    func categories(site: Site) async throws -> [String] { try await spider.categories(site: site) }
    func browse(site: Site, category: String?, page: Int) async throws -> VodPage { try await spider.browse(site: site, category: category, page: page) }
    func search(site: Site, keyword: String, page: Int) async throws -> VodPage { try await spider.search(site: site, keyword: keyword, page: page) }
    func detail(site: Site, vodId: String) async throws -> Vod { try await spider.detail(site: site, vodId: vodId) }
    func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String { try await spider.resolvePlayUrl(site: site, vod: vod, episode: episode) }
}

private struct ManagedAndroidSpiderProxy: VodFetching {
    let spider: ManagedAndroidSpiderClient
    let site: Site
    func categories(site: Site) async throws -> [String] { try await spider.categories(site: site) }
    func browse(site: Site, category: String?, page: Int) async throws -> VodPage { try await spider.browse(site: site, category: category, page: page) }
    func search(site: Site, keyword: String, page: Int) async throws -> VodPage { try await spider.search(site: site, keyword: keyword, page: page) }
    func detail(site: Site, vodId: String) async throws -> Vod { try await spider.detail(site: site, vodId: vodId) }
    func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String { try await spider.resolvePlayUrl(site: site, vod: vod, episode: episode) }
}
