// CatVodClient.swift — CatVod（苹果CMS）标准接口客户端
import Foundation

/// 实现 TVBox 主力源协议（苹果CMS v10 标准 API）：
///   浏览: api + ?ac=detail&t=<type_id>&pg=<页>（t 要 type_id 数字，不是分类名）
///   搜索: ...&wd=<关键词>&pg=<页>
///   详情: ...&ac=detail&ids=<vod_id>
/// 响应: {"code":1,"page":"1","pagecount":"N","limit":"20","total":"N","list":[vod...],"class":[...]}
public actor CatVodClient {
    private let http: HTTPFetching
    private let parseEngine: ParseRuleEngine
    private let adFilter: AdFilter
    public var parses: [ParseRule] = []
    public var globalHeader: [String: String] = [:]
    public var defaultUA: String = HTTPDefaults.defaultUA
    // 分类缓存（按 site.id）：API 的 ac=list/class → (分类名列表, 分类名→type_id 映射)
    private var categoryCache: [String: ([String], [String: Int])] = [:]

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

    /// 请求 catvod 并解码 VodPage
    /// 注意：信封字段宽容解码（部分源 page/pagecount/limit 返回字符串 "1"）；
    /// code 不做失败判定（部分源 code=1 为成功「数据列表」，code=0 也常见），
    /// 只认 list 有无；解码失败带响应片段，方便定位（HTML 反爬页/结构不符）
    private func fetchPage(_ url: String, headers: [String: String]) async throws -> VodPage {
        guard let u = URL(string: url) else { throw HTTPClientError.badURL(url) }
        let (data, _) = try await http.get(u, headers: headers)
        struct CatVodEnvelope: Decodable {
            let code: JSONValue?
            let list: [Vod]?
            let page: JSONValue?
            let pagecount: JSONValue?
            let limit: JSONValue?
            let total: JSONValue?
        }
        guard let env = try? JSONDecoder().decode(CatVodEnvelope.self, from: data) else {
            throw HTTPClientError.jsonParse("\(url) —— \(Self.describe(data))")
        }
        guard let list = env.list else {
            throw HTTPClientError.jsonParse("响应缺少 list: \(url) —— \(Self.describe(data))")
        }
        return VodPage(page: LenientJSON.int(env.page) ?? 1,
                       pagecount: LenientJSON.int(env.pagecount) ?? 0,
                       limit: LenientJSON.int(env.limit) ?? 20,
                       total: LenientJSON.int(env.total) ?? list.count,
                       list: list)
    }

    /// 响应片段（说人话：拿到的是什么一眼可辨）
    static func describe(_ data: Data) -> String {
        guard !data.isEmpty else { return "服务器返回了空内容（0 字节），可能地址不对或被反爬" }
        let head = String(data: data.prefix(150), encoding: .utf8) ?? "(无法按文本读取，可能是二进制)"
        if head.lowercased().contains("<html") || head.lowercased().contains("<!doctype") {
            return "服务器返回的是 HTML 网页（大概率反爬拦截页）。响应开头: \(head.prefix(80))"
        }
        return "响应开头: \(head.prefix(80).replacingOccurrences(of: "\n", with: " "))"
    }

    // MARK: - VodFetching
    public func categories(site: Site) async throws -> [String] {
        if let (names, _) = categoryCache[site.id] { return names }
        // CatVod 的 t= 参数要 type_id 而非分类名：优先从 API 的 ac=list → class 建映射
        let url = buildApiUrl(site.api, query: "ac=list")
        if let u = URL(string: url) {
            if let (data, _) = try? await http.get(u, headers: requestHeaders(site)) {
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let dict = obj as? [String: Any],
                   let cls = dict["class"] as? [[String: Any]] {
                    var names: [String] = []
                    var map: [String: Int] = [:]
                    for item in cls {
                        guard let name = (item["type_name"] as? String)?
                            .trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
                        let id: Int?
                        if let n = item["type_id"] as? NSNumber { id = n.intValue }
                        else if let s = item["type_id"] as? String { id = Int(s) }
                        else { id = nil }
                        guard let id else { continue }
                        if map[name] == nil { names.append(name) }
                        map[name] = id
                    }
                    if !names.isEmpty {
                        categoryCache[site.id] = (names, map)
                        return names
                    }
                }
            }
        }
        // API 取不到 class → 回退配置里的分类（此时 t= 只能传名字，部分源不认）
        return site.categories ?? [""]
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
        var query = "ac=detail"
        if let c = category?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            // 分类名 → type_id（实测 t=分类名 返回 0 条，t=type_id 正常）
            let t = categoryCache[site.id]?.1[c].map(String.init) ?? c
            query += "&t=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)"
        }
        query += "&pg=\(page)"
        return try await fetchPage(buildApiUrl(site.api, query: query), headers: requestHeaders(site))
    }

    public func search(site: Site, keyword: String, page: Int) async throws -> VodPage {
        let wd = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let query = "ac=detail&wd=\(wd)&pg=\(page)"
        return try await fetchPage(buildApiUrl(site.api, query: query), headers: requestHeaders(site))
    }

    public func detail(site: Site, vodId: String) async throws -> Vod {
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
