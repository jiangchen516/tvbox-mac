// SpiderClient.swift — 把 VodFetching 调用翻译成 spider JS 入口调用
import Foundation

/// 针对 type==0（spider）站点的取数实现；与 CatVodClient 平级，
/// 组合层（TVBoxClient）将来按 site.type 分发。
public actor SpiderClient {
    private let runtime: SpiderRuntime
    private let http: HTTPFetching
    public var parses: [ParseRule] = []
    public var globalHeader: [String: String] = [:]
    public var globalSpiderURL: String?          // 配置级 spider 地址（jar/js）

    public init(runtime: SpiderRuntime? = nil, http: HTTPFetching = HttpClient()) {
        self.runtime = runtime ?? SpiderRuntime()
        self.http = http
    }

    public func setParses(_ p: [ParseRule]) { parses = p }

    public func setGlobalHeader(_ h: [String: String]) { globalHeader = h }

    public func setGlobalSpiderURL(_ u: String?) { globalSpiderURL = u }

    private var loadedSourceKey: String?

    /// spider 实现地址候选：site.spider → site.jar → 配置级 spider → site.api（老约定 js 文件）。
    /// 剥 ";md5;hash" 校验后缀；csp_ 类名不是地址，会被过滤。
    private func spiderURLs(for site: Site) -> [String] {
        let candidates = [site.spider, site.jar, globalSpiderURL, site.api].compactMap { $0 }
        var out: [String] = []
        for raw in candidates {
            let u = raw.split(separator: ";").first.map(String.init) ?? raw
            if u.lowercased().hasPrefix("http") && !out.contains(u) { out.append(u) }
        }
        return out
    }

    /// 下载 spider 实现并加载（同站点缓存；换站点换实现时重载）
    private func ensureLoaded(_ site: Site) async throws {
        let candidates = spiderURLs(for: site)
        guard !candidates.isEmpty else {
            throw SpiderError.jsLoadFailed(
                "此源是 Spider 型站点（api=\(site.api)），配置里没有可下载的 spider 实现（jar/js 地址）")
        }
        if await runtime.isLoaded, loadedSourceKey == candidates[0] { return }
        var lastError: Error = SpiderError.jsLoadFailed("找不到 spider 实现: \(candidates.joined(separator: ", "))")
        for u in candidates {
            do {
                let source = try await fetchSpiderSource(u, site: site)
                try await runtime.load(source)
                self.loadedSourceKey = u
                return
            } catch let e as SpiderError {
                // jar 型（无法运行）→ 试下一个候选；全部候选都是 jar 时抛 jar 错误（说人话）
                if case .unsupportedJar = e { lastError = e; continue }
                throw e
            }
        }
        throw lastError
    }

    /// 下载并分类 spider 内容：JS 文本可加载；zip/dex jar 是安卓实现，macOS 无法运行
    private func fetchSpiderSource(_ u: String, site: Site) async throws -> String {
        guard let url = URL(string: IDNA.urlString(u)) else {
            throw SpiderError.jsLoadFailed("spider 地址无效: \(u)")
        }
        let (data, _) = try await http.get(url, headers: ["User-Agent": site.ua ?? HTTPDefaults.defaultUA])
        if let s = String(data: data, encoding: .utf8), s.contains("function") || s.contains("=>") {
            return s
        }
        if Self.looksLikeJar(data) {
            throw SpiderError.unsupportedJar(site.api.isEmpty ? u : site.api)
        }
        throw SpiderError.jsLoadFailed("spider 内容不是 JS: \(u)")
    }

    /// zip（PK）或 dex（"dex\n"）魔数 → 安卓 jar
    static func looksLikeJar(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        if b.count >= 2 && b[0] == 0x50 && b[1] == 0x4B { return true }
        if b.elementsEqual(Array("dex\n".utf8)) { return true }
        return false
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
