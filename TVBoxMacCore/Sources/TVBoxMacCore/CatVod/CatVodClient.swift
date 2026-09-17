// CatVodClient.swift — CatVod（苹果CMS）标准接口客户端
import Foundation

/// 实现 TVBox 主力源协议（苹果CMS v10 标准 API）：
///   浏览: api + ?ac=detail&t=<分类>&pg=<页>
///   搜索: ...&wd=<关键词>&pg=<页>
///   详情: ...&ac=detail&ids=<vod_id>
/// 响应: {"code":0,"page":1,"pagecount":N,"limit":20,"total":N,"list":[vod...]}
public actor CatVodClient {
    private let http: HTTPFetching
    private let parseEngine: ParseRuleEngine
    private let adFilter: AdFilter
    public var parses: [ParseRule] = []
    public var globalHeader: [String: String] = [:]
    public var defaultUA: String = HTTPDefaults.defaultUA

    public init(http: HTTPFetching = HttpClient(),
                parseEngine: ParseRuleEngine? = nil,
                adFilter: AdFilter = .init()) {
        self.http = http
        self.parseEngine = parseEngine ?? ParseRuleEngine(http: http)
        self.adFilter = adFilter
    }

    public func setParses(_ p: [ParseRule]) { parses = p }
    public func setGlobalHeader(_ h: [String: String]) { globalHeader = h }

    // MARK: - URL 构造（api 可能已含 ? 或带/不带尾部斜杠，两种都兼容）
    func buildApiUrl(_ api: String, query: String) -> String {
        let trimmed = api.hasSuffix("/") ? String(api.dropLast()) : api
        if trimmed.contains("?") {
            return trimmed + "&" + query
        }
        return trimmed + "?" + query
    }

    private func requestHeaders(_ site: Site) -> [String: String] {
        var h = globalHeader
        for (k, v) in HeaderParser.parse(site.header) { h[k] = v }
        if let ua = site.ua, !ua.isEmpty { h["User-Agent"] = ua }
        return h
    }

    /// 请求 catvod 并解码 VodPage；code!=0 或无 list 抛错
    private func fetchPage(_ url: String, headers: [String: String]) async throws -> VodPage {
        guard let u = URL(string: url) else { throw HTTPClientError.badURL(url) }
        let (data, _) = try await http.get(u, headers: headers)
        struct CatVodResponse: Decodable {
            let code: Int?
            let list: [Vod]?
            let page: Int?
            let pagecount: Int?
            let limit: Int?
            let total: Int?
        }
        guard let resp = try? JSONDecoder().decode(CatVodResponse.self, from: data) else {
            throw HTTPClientError.jsonParse(url)
        }
        if let code = resp.code, code != 0 {
            throw HTTPClientError.httpStatus(code, "catvod 返回 code=\(code): \(url)")
        }
        guard let list = resp.list else {
            throw HTTPClientError.jsonParse("响应缺少 list: \(url)")
        }
        return VodPage(page: resp.page ?? 1,
                       pagecount: resp.pagecount ?? 0,
                       limit: resp.limit ?? 20,
                       total: resp.total ?? list.count,
                       list: list)
    }

    // MARK: - VodFetching
    public func categories(site: Site) async throws -> [String] {
        // CatVod 无独立分类端点，分类名来自配置
        site.categories ?? [""]
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
        var query = "ac=detail"
        if let c = category?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            query += "&t=\(c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c)"
        }
        query += "&pg=\(page)"
        return try await fetchPage(buildApiUrl(site.api, query: query), headers: requestHeaders(site))
    }

    public func search(site: Site, keyword: String, page: Int) async throws -> VodPage {
        let wd = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let query = "ac=detail&wd=\(wd)&pg=\(page)"
        return try await fetchPage(buildApiUrl(site.api, query: query), headers: requestHeaders(site))
    }

    public func detail(site: Site, vodId: Int) async throws -> Vod {
        let query = "ac=detail&ids=\(vodId)"
        let page = try await fetchPage(buildApiUrl(site.api, query: query), headers: requestHeaders(site))
        guard let vod = page.list.first else {
            throw HTTPClientError.jsonParse("详情未找到 id=\(vodId)")
        }
        return vod
    }

    public func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String {
        var url = episode.url
        // 二次解析地址：url= 参数里 base64 编码了真实播放地址（TVBox 常见模式）
        if let u = URL(string: url),
           let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
           let encoded = comps.queryItems?.first(where: { $0.name == "url" })?.value,
           let data = Data(base64Encoded: encoded),
           let decoded = String(data: data, encoding: .utf8),
           decoded.lowercased().hasPrefix("http") {
            url = decoded
        }
        // 广告过滤（url 形态）
        url = adFilter.apply(to: url, rules: nil)
        // 无 parse 规则 → 地址直接可播
        guard let rule = parses.first else { return url }
        let ua = site.ua ?? defaultUA
        return try await parseEngine.resolve(url: url, rule: rule,
                                             siteHeader: requestHeaders(site),
                                             globalHeader: globalHeader, ua: ua)
    }
}
