// SpiderClient.swift — 把 VodFetching 调用翻译成 spider JS 入口调用
import Foundation

/// 针对 type==0（spider）站点的取数实现；与 CatVodClient 平级，
/// 组合层（TVBoxClient）将来按 site.type 分发。
public actor SpiderClient {
    private let runtime: SpiderRuntime
    private let http: HTTPFetching
    public var parses: [ParseRule] = []
    public var globalHeader: [String: String] = [:]

    public init(runtime: SpiderRuntime? = nil, http: HTTPFetching = HttpClient()) {
        self.runtime = runtime ?? SpiderRuntime()
        self.http = http
    }

    public func setParses(_ p: [ParseRule]) { parses = p }

    public func setGlobalHeader(_ h: [String: String]) { globalHeader = h }

    private var loadedSource: String?

    /// 从 site.spider / site.api 下载 spider JS 并加载（缓存内存内）
    private func ensureLoaded(_ site: Site) async throws {
        if await runtime.isLoaded { return }
        guard let source = await loadSpiderSource(site) else {
            throw SpiderError.jsLoadFailed("找不到 spider JS: \(site.api)")
        }
        try await runtime.load(source)
        self.loadedSource = source
    }

    private func loadSpiderSource(_ site: Site) async -> String? {
        let candidates = [site.spider, site.api].compactMap { $0 }
        for u in candidates where u.lowercased().hasPrefix("http") {
            guard let url = URL(string: u) else { continue }
            do {
                let (data, _) = try await http.get(url, headers: ["User-Agent": site.ua ?? HTTPDefaults.defaultUA])
                if let s = String(data: data, encoding: .utf8), s.contains("function") || s.contains("=>") {
                    return s
                }
            } catch {}
        }
        return nil
    }

    // MARK: - VodFetching
    public func categories(site: Site) async throws -> [String] {
        // spider 站的分类来自 home_video 或配置；这里先回配置
        site.categories ?? [""]
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
        try await ensureLoaded(site)
        let types = category ?? ""
        let jsonStr = try await runtime.home(types: types, filters: nil, page: page)
        struct R: Decodable { let list: [Vod]; let page: Int?; let pagecount: Int?; let total: Int? }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(jsonStr.utf8)) else {
            throw SpiderError.jsException("home_video 返回非法 JSON")
        }
        return VodPage(page: r.page ?? page, pagecount: r.pagecount ?? 0,
                       limit: 20, total: r.total ?? r.list.count, list: r.list)
    }

    public func search(site: Site, keyword: String, page: Int) async throws -> VodPage {
        try await ensureLoaded(site)
        let jsonStr = try await runtime.search(key: keyword, page: page)
        struct R: Decodable { let list: [Vod] }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(jsonStr.utf8)) else {
            throw SpiderError.jsException("search_video 返回非法 JSON")
        }
        return VodPage(page: page, pagecount: 1, limit: 20, total: r.list.count, list: r.list)
    }

    public func detail(site: Site, vodId: Int) async throws -> Vod {
        try await ensureLoaded(site)
        let jsonStr = try await runtime.detail(id: "\(vodId)")
        struct R: Decodable { let list: [Vod] }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(jsonStr.utf8)),
              let vod = r.list.first else {
            throw SpiderError.jsException("detail_video 未找到")
        }
        return vod
    }

    public func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String {
        try await ensureLoaded(site)
        // play_video 的 id 约定：vodId 或 "vodId-剧集url"；TVBox 用 play_url 原文
        let jsonStr = try await runtime.play(id: "\(vod.vod_id)")
        struct R: Decodable { let url: String?; let parse: Int?; let header: String? }
        guard let r = try? JSONDecoder().decode(R.self, from: Data(jsonStr.utf8)),
              let u = r.url, !u.isEmpty else {
            throw SpiderError.jsException("play_video 未返回 url")
        }
        return u
    }
}
