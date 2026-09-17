// Models.swift — TVBoxMacCore 共享类型契约（所有模块按此签名，勿改已有签名；可追加 public 字段）
//
// 字段依据：TVBox 安卓源码 ApiConfig.java / SiteBean.java / ParseBean.java（本地 .tmp_java/）
//   顶层配置键: sites / parses / flags / spider / lives / ads / ijk / rules
//   聚合列表键: urls（iyouhun 等聚合仓格式）
//   Site 键:    key, name, api, type, categories, searchable, quickSearch, filterable, playUrl, ext,
//               jar,（新版可选）header, ua, spider
//   Parse 键:   name, url, type(0=直接拼接,1=JSON解析), ext(JSON对象, base64url 后作 cat_ext 参数)
//
// ⚠️ 真实源配置千差万别（字段缺失/类型漂移），TVBoxConfig/Site/ParseRule/Vod
//    全部走"宽容解码"（经 JSONValue 中转），缺字段给默认值而不是崩。
import Foundation

// MARK: - 宽容 JSON 值
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// 转 Foundation 原生类型（供 JSONSerialization 等使用）
    public var asAny: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .array(let a): return a.map { $0.asAny }
        case .object(let o): return o.mapValues { $0.asAny }
        case .null: return NSNull()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// 兼容 TVBox 的字符串 ext（可能是 JSON 字符串，也可能就是普通字符串）
    public init(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let d = trimmed.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) {
            self = LenientJSON.json(o)
            return
        }
        self = .string(s)
    }

    /// 按点路径取子值："a.b.0.c"；支持 "$." 前缀
    public func value(at path: String) -> JSONValue? {
        var cur: JSONValue = self
        var segs = path.split(separator: ".").map(String.init)
        if segs.first == "$" { segs.removeFirst() }
        for seg in segs where !seg.isEmpty {
            switch cur {
            case .object(let dict):
                guard let next = dict[seg] else { return nil }
                cur = next
            case .array(let arr):
                guard let i = Int(seg), i < arr.count else { return nil }
                cur = arr[i]
            default:
                return nil
            }
        }
        return cur
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n) where n.isFinite:
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }
}

// MARK: - 配置
public struct TVBoxConfig: Codable, Sendable {
    public var sites: [Site]                  // 站点数组（TVBox 键 "sites"）
    public var parses: [ParseRule]
    public var flags: [String]
    public var spider: String?
    public var lives: [JSONValue]
    public var ads: [String]
    public var ijk: [JSONValue]
    public var header: String?
    public var wallpaper: String?
    public var timeout: Int
    public var rules: [String: JSONValue]

    public init(sites: [Site], parses: [ParseRule] = [], flags: [String] = [],
                spider: String? = nil, lives: [JSONValue] = [], ads: [String] = [],
                ijk: [JSONValue] = [], header: String? = nil, wallpaper: String? = nil,
                timeout: Int = 15, rules: [String: JSONValue]? = nil) {
        self.sites = sites
        self.parses = parses
        self.flags = flags
        self.spider = spider
        self.lives = lives
        self.ads = ads
        self.ijk = ijk
        self.header = header
        self.wallpaper = wallpaper
        self.timeout = timeout
        self.rules = rules ?? [:]
    }

    // 宽容解码
    public init(from decoder: Decoder) throws {
        let raw = try LenientJSON.object(from: decoder)
        var sites: [Site] = []
        if case .array(let arr)? = raw["sites"] {
            for item in arr {
                if case .object(let d) = item, let s = try? Site(fromDict: d) {
                    sites.append(s)
                }
            }
        }
        var parses: [ParseRule] = []
        if case .array(let arr)? = raw["parses"] {
            for item in arr {
                if case .object(let d) = item, let p = try? ParseRule(fromDict: d) {
                    parses.append(p)
                }
            }
        }
        self.sites = sites
        self.parses = parses
        self.flags = LenientJSON.stringArray(raw["flags"])
        self.spider = LenientJSON.str(raw["spider"])
        self.lives = LenientJSON.valueArray(raw["lives"])
        self.ads = LenientJSON.stringArray(raw["ads"])
        self.ijk = LenientJSON.valueArray(raw["ijk"])
        self.header = LenientJSON.str(raw["header"])
        self.wallpaper = LenientJSON.str(raw["wallpaper"])
        self.timeout = LenientJSON.int(raw["timeout"]) ?? 15
        self.rules = LenientJSON.objectValue(raw["rules"]) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KV.self)
        try c.encode(sites, forKey: .sites)
        try c.encode(parses, forKey: .parses)
        try c.encode(flags, forKey: .flags)
        try c.encodeIfPresent(spider, forKey: .spider)
        try c.encode(lives, forKey: .lives)
        try c.encode(ads, forKey: .ads)
        try c.encode(ijk, forKey: .ijk)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encodeIfPresent(wallpaper, forKey: .wallpaper)
        try c.encode(timeout, forKey: .timeout)
        try c.encode(rules, forKey: .rules)
    }

    private enum KV: String, CodingKey {
        case sites, parses, flags, spider, lives, ads, ijk, header, wallpaper, timeout, rules
    }
}

/// iyouhun 等聚合列表格式: {"urls": [{"name": "...", "url": "配置JSON地址"}]}
public struct AggregateList: Codable, Sendable {
    public var urls: [AggregateEntry]
    public init(urls: [AggregateEntry]) { self.urls = urls }
}

public struct AggregateEntry: Codable, Sendable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public struct Site: Codable, Sendable, Identifiable, Hashable {
    public var key: String                    // 站点唯一 key
    public var name: String
    public var api: String                    // catvod URL（type=1）或 spider JS URL / csp_ 类名（type=0/3）
    public var type: Int                      // 0=js spider, 1=catvod/json, 3=jar spider（api 为 csp_ 类名）
    public var categories: [String]?
    public var searchable: Int
    public var quickSearch: Int
    public var filterable: Int
    public var playUrl: String?
    public var ext: JSONValue?
    public var jar: String?                   // 站点级 spider jar/js 地址（type=3 常见）
    public var header: String?
    public var ua: String?
    public var spider: String?

    public var id: String { key.isEmpty ? (name + "|" + api) : key }

    /// spider 型站点：type 0/3，或 api 为 csp_ 前缀（TVBox 约定：api 是 spider 类名不是 URL）
    public var isSpiderSite: Bool {
        type == 0 || type == 3 || api.lowercased().hasPrefix("csp_")
    }

    public init(key: String = "", name: String, api: String, type: Int = 1,
                categories: [String]? = nil, searchable: Int = 1, quickSearch: Int = 1,
                filterable: Int = 1, playUrl: String? = nil, ext: JSONValue? = nil,
                jar: String? = nil, header: String? = nil, ua: String? = nil, spider: String? = nil) {
        self.key = key
        self.name = name
        self.api = api
        self.type = type
        self.categories = categories
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.filterable = filterable
        self.playUrl = playUrl
        self.ext = ext
        self.jar = jar
        self.header = header
        self.ua = ua
        self.spider = spider
    }

    public init(from decoder: Decoder) throws {
        let raw = try LenientJSON.object(from: decoder)
        self.init(fromDict: raw)
    }

    init(fromDict raw: [String: JSONValue]) {
        self.key = LenientJSON.str(raw["key"]) ?? ""
        self.name = LenientJSON.str(raw["name"]) ?? "未知站点"
        self.api = LenientJSON.str(raw["api"]) ?? ""
        self.type = LenientJSON.int(raw["type"]) ?? 1
        let cats = LenientJSON.stringArray(raw["categories"])
        self.categories = cats.isEmpty ? nil : cats
        self.searchable = LenientJSON.int(raw["searchable"]) ?? 1
        self.quickSearch = LenientJSON.int(raw["quickSearch"]) ?? 1
        self.filterable = LenientJSON.int(raw["filterable"]) ?? 1
        self.playUrl = LenientJSON.str(raw["playUrl"])
        self.ext = raw["ext"]
        self.jar = LenientJSON.str(raw["jar"])
        self.header = LenientJSON.str(raw["header"])
        self.ua = LenientJSON.str(raw["ua"])
        self.spider = LenientJSON.str(raw["spider"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KV.self)
        try c.encode(key, forKey: .key)
        try c.encode(name, forKey: .name)
        try c.encode(api, forKey: .api)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(categories, forKey: .categories)
        try c.encode(searchable, forKey: .searchable)
        try c.encode(quickSearch, forKey: .quickSearch)
        try c.encode(filterable, forKey: .filterable)
        try c.encodeIfPresent(playUrl, forKey: .playUrl)
        try c.encodeIfPresent(ext, forKey: .ext)
        try c.encodeIfPresent(jar, forKey: .jar)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encodeIfPresent(ua, forKey: .ua)
        try c.encodeIfPresent(spider, forKey: .spider)
    }

    private enum KV: String, CodingKey {
        case key, name, api, type, categories, searchable, quickSearch, filterable,
             playUrl, ext, jar, header, ua, spider
    }
}

public struct ParseRule: Codable, Sendable {
    public var name: String
    public var url: String
    public var type: Int                      // 0=直接URL拼接, 1=JSON解析
    public var header: String?
    public var ext: JSONValue?

    public init(name: String, url: String, type: Int = 0, header: String? = nil, ext: JSONValue? = nil) {
        self.name = name
        self.url = url
        self.type = type
        self.header = header
        self.ext = ext
    }

    public init(from decoder: Decoder) throws {
        let raw = try LenientJSON.object(from: decoder)
        self.init(fromDict: raw)
    }

    init(fromDict raw: [String: JSONValue]) {
        self.name = LenientJSON.str(raw["name"]) ?? ""
        self.url = LenientJSON.str(raw["url"]) ?? ""
        self.type = LenientJSON.int(raw["type"]) ?? 0
        self.header = LenientJSON.str(raw["header"])
        self.ext = raw["ext"]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: KV.self)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encodeIfPresent(ext, forKey: .ext)
    }

    private enum KV: String, CodingKey { case name, url, type, header, ext }
}

/// 用户已导入的一份配置（持久化用）
public struct LoadedConfig: Codable, Sendable, Identifiable {
    public var name: String
    public var url: String
    public var config: TVBoxConfig
    public var enabled: Bool

    public var id: String { name + "|" + url }

    public init(name: String, url: String, config: TVBoxConfig, enabled: Bool = true) {
        self.name = name
        self.url = url
        self.config = config
        self.enabled = enabled
    }
}

// MARK: - CatVod 数据
public struct Vod: Codable, Sendable, Identifiable {
    public var vod_id: Int
    public var vod_name: String
    public var type_id: Int?
    public var type_name: String?
    public var vod_year: String?
    public var vod_area: String?
    public var vod_remarks: String?
    public var vod_pic: String?
    public var vod_actor: String?
    public var vod_director: String?
    public var vod_content: String?
    public var vod_play_from: String?         // "线路1#线路2"
    public var vod_play_url: String?          // "第1集|http..#第2集|http..$$$第1集|http.."
    public var vod_play_note: String?
    public var vod_score: String?
    public var vod_time: String?
    public var vod_blurb: String?

    public var id: Int { vod_id }

    public init(vod_id: Int, vod_name: String, type_id: Int? = nil, type_name: String? = nil,
                vod_year: String? = nil, vod_area: String? = nil, vod_remarks: String? = nil,
                vod_pic: String? = nil, vod_actor: String? = nil, vod_director: String? = nil,
                vod_content: String? = nil, vod_play_from: String? = nil, vod_play_url: String? = nil,
                vod_play_note: String? = nil, vod_score: String? = nil, vod_time: String? = nil,
                vod_blurb: String? = nil) {
        self.vod_id = vod_id
        self.vod_name = vod_name
        self.type_id = type_id
        self.type_name = type_name
        self.vod_year = vod_year
        self.vod_area = vod_area
        self.vod_remarks = vod_remarks
        self.vod_pic = vod_pic
        self.vod_actor = vod_actor
        self.vod_director = vod_director
        self.vod_content = vod_content
        self.vod_play_from = vod_play_from
        self.vod_play_url = vod_play_url
        self.vod_play_note = vod_play_note
        self.vod_score = vod_score
        self.vod_time = vod_time
        self.vod_blurb = vod_blurb
    }

    // 宽容解码：部分源缺字段
    public init(from decoder: Decoder) throws {
        let raw = try LenientJSON.object(from: decoder)
        self.vod_id = LenientJSON.int(raw["vod_id"]) ?? 0
        self.vod_name = LenientJSON.str(raw["vod_name"]) ?? "未知"
        self.type_id = LenientJSON.int(raw["type_id"])
        self.type_name = LenientJSON.str(raw["type_name"])
        self.vod_year = LenientJSON.str(raw["vod_year"])
        self.vod_area = LenientJSON.str(raw["vod_area"])
        self.vod_remarks = LenientJSON.str(raw["vod_remarks"])
        self.vod_pic = LenientJSON.str(raw["vod_pic"])
        self.vod_actor = LenientJSON.str(raw["vod_actor"])
        self.vod_director = LenientJSON.str(raw["vod_director"])
        self.vod_content = LenientJSON.str(raw["vod_content"])
        self.vod_play_from = LenientJSON.str(raw["vod_play_from"])
        self.vod_play_url = LenientJSON.str(raw["vod_play_url"])
        self.vod_play_note = LenientJSON.str(raw["vod_play_note"])
        self.vod_score = LenientJSON.str(raw["vod_score"])
        self.vod_time = LenientJSON.str(raw["vod_time"])
        self.vod_blurb = LenientJSON.str(raw["vod_blurb"])
    }
}

public struct Episode: Codable, Sendable, Identifiable {
    public var title: String
    public var url: String
    public var group: String
    public var index: Int

    public var id: String { "\(group)#\(index)#\(url)" }

    /// 直连媒体地址（AVPlayer 可直接播；网页播放页需要解析，播不了）
    public var isDirectMedia: Bool {
        let low = url.lowercased()
        return low.contains(".m3u8") || low.contains(".mp4") || low.contains(".flv")
            || low.contains(".ts") || low.contains(".mp3") || low.contains(".m4a")
    }

    public init(title: String, url: String, group: String, index: Int) {
        self.title = title
        self.url = url
        self.group = group
        self.index = index
    }
}

public extension Vod {
    /// 播放组名列表（vod_play_from 按 # 拆）
    var playGroups: [String] {
        guard let from = vod_play_from, !from.isEmpty else { return [] }
        return from.split(separator: "#", omittingEmptySubsequences: true).map(String.init)
    }

    /// 取指定播放组的剧集列表
    /// vod_play_url: 组间 $$$，组内集间 #，每集 "title|url"（title 可空 → "第N集"）
    func episodes(group: String) -> [Episode] {
        guard let raw = vod_play_url, !raw.isEmpty else { return [] }
        let decoded = raw.removingPercentEncoding ?? raw
        let groups = decoded.components(separatedBy: "$$$")
        let groupIdx = playGroups.firstIndex(of: group) ?? 0
        guard groupIdx < groups.count else { return [] }
        let items = groups[groupIdx].components(separatedBy: "#")
        var result: [Episode] = []
        for item in items {
            let parts = item.components(separatedBy: "|")
            guard let url = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { continue }
            let t = parts.count >= 2 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let title = t.isEmpty ? "第\(result.count + 1)集" : t
            result.append(Episode(title: title, url: url, group: group, index: result.count))
        }
        return result
    }
}

public struct VodPage: Codable, Sendable {
    public var page: Int
    public var pagecount: Int
    public var limit: Int
    public var total: Int
    public var list: [Vod]

    public init(page: Int, pagecount: Int, limit: Int, total: Int, list: [Vod]) {
        self.page = page
        self.pagecount = pagecount
        self.limit = limit
        self.total = total
        self.list = list
    }
}

// MARK: - 取数协议（CatVodClient / SpiderClient 各自实现，UI 只依赖它）
public protocol VodFetching: Sendable {
    func categories(site: Site) async throws -> [String]
    func browse(site: Site, category: String?, page: Int) async throws -> VodPage
    func search(site: Site, keyword: String, page: Int) async throws -> VodPage
    func detail(site: Site, vodId: Int) async throws -> Vod
    func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String
}

/// 站点暂不支持
public struct UnsupportedSiteError: Error, Sendable {
    public let site: String
    public init(site: String) { self.site = site }
    public var errorDescription: String? { "站点暂不支持: \(site)" }
}

// MARK: - Header 解析（"k:v;k:v" 或 JSON 字符串）
public enum HeaderParser {
    public static func parse(_ raw: String?) -> [String: String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [:] }
        if raw.hasPrefix("{") {
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var out: [String: String] = [:]
                for (k, v) in obj { out[k] = "\(v)" }
                return out
            }
        }
        var out: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            out[kv[0]] = kv[1]
        }
        return out
    }
}

// MARK: - 宽容解码工具
public enum LenientJSON {
    /// 把 decoder 指向的 JSON 对象转成 [String: JSONValue]（非对象抛错）
    public static func object(from decoder: Decoder) throws -> [String: JSONValue] {
        let v = try JSONValue(from: decoder)
        guard case .object(let d) = v else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "期望 JSON 对象"))
        }
        return d
    }

    public static func str(_ v: JSONValue?) -> String? { v?.stringValue }

    public static func int(_ v: JSONValue?) -> Int? {
        switch v {
        case .number(let n) where n.isFinite: return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public static func stringArray(_ v: JSONValue?) -> [String] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { $0.stringValue }
    }

    public static func valueArray(_ v: JSONValue?) -> [JSONValue] {
        guard case .array(let a)? = v else { return [] }
        return a
    }

    public static func objectValue(_ v: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let d)? = v else { return nil }
        return d
    }

    /// 任意 JSONSerialization 值 → JSONValue
    public static func json(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let s = any as? String { return .string(s) }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? NSNumber { return .number(n.doubleValue) }
        if let arr = any as? [Any] { return .array(arr.map { json($0) }) }
        if let d = any as? [String: Any] { return .object(d.mapValues { json($0) }) }
        return .null
    }
}
