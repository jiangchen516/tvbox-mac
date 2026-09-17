// TVBoxClient.swift — 组合取数层：按 site.type 分发到 CatVodClient / SpiderClient
import Foundation

public actor TVBoxClient {
    private let catVod: CatVodClient
    private let spider: SpiderClient
    public private(set) var loadedConfigs: [LoadedConfig] = []

    public init(catVod: CatVodClient? = nil, spider: SpiderClient? = nil) {
        self.catVod = catVod ?? CatVodClient()
        self.spider = spider ?? SpiderClient()
    }

    /// 加载配置后同步 parses/header 到两个 client
    public func configure(_ config: TVBoxConfig) async {
        await catVod.setParses(config.parses)
        await spider.setParses(config.parses)
        let h = HeaderParser.parse(config.header)
        await catVod.setGlobalHeader(h)
        await spider.setGlobalHeader(h)
    }

    public func allSites() -> [Site] {
        loadedConfigs.flatMap { $0.config.sites }
    }

    public func loadConfigs(_ configs: [LoadedConfig]) async {
        loadedConfigs = configs
        // 默认用第一份配置的 parses/header
        if let first = configs.first {
            await configure(first.config)
        }
    }

    // MARK: - VodFetching 风格的分发（UI 直接用这些方法）
    private func client(for site: Site) -> any VodFetching {
        // type==0 → spider, type==1 → catvod（与 TVBox 一致）
        // 注意 SpiderClient 未实现 VodFetching（actor 隔离），这里用类型分发
        if site.type == 0 {
            return SpiderProxy(spider: spider, site: site)
        }
        return CatVodProxy(catVod: catVod, site: site)
    }

    public func categories(site: Site) async throws -> [String] {
        try await client(for: site).categories(site: site)
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
        try await client(for: site).browse(site: site, category: category, page: page)
    }

    public func search(site: Site, keyword: String, page: Int) async throws -> VodPage {
        try await client(for: site).search(site: site, keyword: keyword, page: page)
    }

    public func detail(site: Site, vodId: Int) async throws -> Vod {
        try await client(for: site).detail(site: site, vodId: vodId)
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
    func detail(site: Site, vodId: Int) async throws -> Vod { try await catVod.detail(site: site, vodId: vodId) }
    func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String { try await catVod.resolvePlayUrl(site: site, vod: vod, episode: episode) }
}

private struct SpiderProxy: VodFetching {
    let spider: SpiderClient
    let site: Site
    func categories(site: Site) async throws -> [String] { try await spider.categories(site: site) }
    func browse(site: Site, category: String?, page: Int) async throws -> VodPage { try await spider.browse(site: site, category: category, page: page) }
    func search(site: Site, keyword: String, page: Int) async throws -> VodPage { try await spider.search(site: site, keyword: keyword, page: page) }
    func detail(site: Site, vodId: Int) async throws -> Vod { try await spider.detail(site: site, vodId: vodId) }
    func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String { try await spider.resolvePlayUrl(site: site, vod: vod, episode: episode) }
}
