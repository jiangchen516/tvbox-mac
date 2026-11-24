// LiveModels.swift — 直播源 / 频道模型
//
// TVBox 配置里的直播源写在顶层 "lives" 数组，典型形态：
//   {"name":"频道1","url":"https://…/live.txt","ua":"…","epg":"…","logo":"…","playerType":"…"}
// 也允许直接给一个 URL 字符串。url 指向在线 txt / m3u 播放列表。
// 少数源没有 url（由 spider 动态提供频道），当前版本不支持，这里保留字段并给出原因，
// 让 UI 能明确提示，而不是把它当成坏源静默丢掉。
import Foundation

public struct LiveSource: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var url: String
    public var group: String?
    public var ua: String?
    public var header: String?
    public var epg: String?
    public var logo: String?
    public var playerType: String?
    public var type: Int
    public var ext: JSONValue?
    /// 内联频道（FongMi 风格）：{"group":"…","channels":[{"name":"…","urls":["…"]}]}
    public var inlineChannels: [LiveChannel]

    public var id: String { "\(name)|\(url)|\(group ?? "")|\(inlineChannels.count)" }

    public init(name: String, url: String, group: String? = nil, ua: String? = nil,
                header: String? = nil, epg: String? = nil, logo: String? = nil,
                playerType: String? = nil, type: Int = 0, ext: JSONValue? = nil,
                inlineChannels: [LiveChannel] = []) {
        self.name = name
        self.url = url
        self.group = group
        self.ua = ua
        self.header = header
        self.epg = epg
        self.logo = logo
        self.playerType = playerType
        self.type = type
        self.ext = ext
        self.inlineChannels = inlineChannels
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, group, ua, header, epg, logo, playerType, type, ext, inlineChannels
        /// 配置里的内联频道键名是 "channels"；解码时两种写法都接受
        case configChannels = "channels"
    }

    /// 宽容解码：缺省字段用默认值；内联频道兼容配置里的 "channels" 键，
    /// 老配置的频道没有 headers 字段也不会抛错。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "直播源"
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        group = try container.decodeIfPresent(String.self, forKey: .group)
        ua = try container.decodeIfPresent(String.self, forKey: .ua)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        epg = try container.decodeIfPresent(String.self, forKey: .epg)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        playerType = try container.decodeIfPresent(String.self, forKey: .playerType)
        type = try container.decodeIfPresent(Int.self, forKey: .type) ?? 0
        ext = try container.decodeIfPresent(JSONValue.self, forKey: .ext)
        if let channels = try container.decodeIfPresent([LiveChannel].self, forKey: .inlineChannels) {
            inlineChannels = channels
        } else if let channels = try container.decodeIfPresent([LiveChannel].self, forKey: .configChannels) {
            inlineChannels = channels
        } else {
            inlineChannels = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(ua, forKey: .ua)
        try container.encodeIfPresent(header, forKey: .header)
        try container.encodeIfPresent(epg, forKey: .epg)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(playerType, forKey: .playerType)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(ext, forKey: .ext)
        // 保持原有编码键名，避免影响既有的持久化数据
        try container.encode(inlineChannels, forKey: .inlineChannels)
    }

    public var hasInlineChannels: Bool { !inlineChannels.isEmpty }

    /// 是否是可抓取的在线播放列表（当前唯一支持的类型）
    public var isHTTPPlaylist: Bool {
        let low = url.lowercased()
        return low.hasPrefix("http://") || low.hasPrefix("https://")
    }

    /// 不能在当前版本播放时的原因（UI 直接展示）
    public var unsupportedReason: String? {
        if isHTTPPlaylist || hasInlineChannels { return nil }
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "这个直播源没有 URL，可能需要 Spider 类直播实现；当前版本还不支持"
        }
        return "直播源地址不是 HTTP/HTTPS，当前版本只支持在线 m3u/txt 播放列表"
    }

    /// 抓取播放列表 / 播放频道时使用的请求头：header 里的键值 + ua（ua 优先）
    public var requestHeaders: [String: String] {
        var headers = HeaderParser.parse(header)
        if let ua, !ua.isEmpty {
            headers["User-Agent"] = ua
        } else if !headers.keys.contains(where: {
            $0.caseInsensitiveCompare("User-Agent") == .orderedSame
        }) {
            headers["User-Agent"] = HTTPDefaults.defaultUA
        }
        return headers
    }

    /// 播放某个频道使用的请求头：以 requestHeaders 为底，频道级 headers 覆盖同名键。
    /// 键名比较不区分大小写，UA / Referer 输出统一用规范写法。
    public func playbackHeaders(for channel: LiveChannel) -> [String: String] {
        var merged: [String: String] = [:]
        for (key, value) in requestHeaders {
            let canonical = Self.canonicalHeaderName(key)
            // 同一个头出现大小写不同的两份时，优先规范写法
            if merged[canonical] != nil, key != canonical { continue }
            merged[canonical] = value
        }
        for (key, value) in channel.headers {
            let canonical = Self.canonicalHeaderName(key)
            guard !canonical.isEmpty else { continue }
            let stale = merged.keys.filter {
                Self.canonicalHeaderName($0).lowercased() == canonical.lowercased()
            }
            for existing in stale { merged.removeValue(forKey: existing) }
            merged[canonical] = value
        }
        return merged
    }

    /// 请求头键名规范化：UA / Referer 用客户端惯用的写法（同时接受 VLC 的 http-* 写法），
    /// 其它键保持原样。
    static func canonicalHeaderName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "user-agent", "http-user-agent":
            return "User-Agent"
        case "referer", "referrer", "http-referer", "http-referrer":
            return "Referer"
        default:
            return name
        }
    }

    /// 从配置的 lives 数组元素构造。relativeURL 相对配置 URL 解析（和 spider jar 一致）。
    /// - Parameters:
    ///   - raw: lives 数组中的一个元素（对象或裸 URL 字符串）
    ///   - configURL: 配置自身的 URL（本地配置传 "local:…" 即可，非 http 时只做去空白）
    ///   - index: 在数组中的序号（生成兜底名称用）
    public static func make(from raw: JSONValue, configURL: String?, index: Int) -> LiveSource {
        switch raw {
        case .string(let value):
            let url = resolveLiveURL(value, against: configURL)
            return LiveSource(name: defaultName(for: url, index: index), url: url)
        case .object(let dict):
            let rawURL = LenientJSON.str(dict["url"]) ?? ""
            let url = resolveLiveURL(rawURL, against: configURL)
            let group = nonEmpty(LenientJSON.str(dict["group"]))
            let name = nonEmpty(LenientJSON.str(dict["name"]))
                ?? defaultName(for: url, index: index)
            return LiveSource(
                name: name,
                url: url,
                group: group,
                ua: nonEmpty(LenientJSON.str(dict["ua"])),
                header: nonEmpty(LenientJSON.str(dict["header"])),
                epg: nonEmpty(LenientJSON.str(dict["epg"])),
                logo: nonEmpty(LenientJSON.str(dict["logo"])),
                playerType: nonEmpty(LenientJSON.str(dict["playerType"])),
                type: LenientJSON.int(dict["type"]) ?? 0,
                ext: dict["ext"],
                inlineChannels: inlineChannels(from: dict["channels"],
                                               defaultGroup: group ?? "未分类")
            )
        default:
            return LiveSource(name: "直播源 \(index + 1)", url: "")
        }
    }

    /// lives[].channels（内联频道）→ [LiveChannel]；缺 name/urls 的条目跳过
    private static func inlineChannels(from raw: JSONValue?, defaultGroup: String) -> [LiveChannel] {
        guard case .array(let items)? = raw else { return [] }
        var result: [LiveChannel] = []
        for (index, item) in items.enumerated() {
            guard case .object(let dict) = item else { continue }
            let name = nonEmpty(LenientJSON.str(dict["name"])) ?? "频道 \(index + 1)"
            var urls: [String] = []
            if case .array(let rawURLs)? = dict["urls"] {
                urls = rawURLs.compactMap { $0.stringValue }
            } else if let joined = LenientJSON.str(dict["urls"]) {
                urls = joined.components(separatedBy: "#")
            }
            if let single = LenientJSON.str(dict["url"]) { urls.append(single) }
            urls = urls
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var unique: [String] = []
            for url in urls where !unique.contains(url) { unique.append(url) }
            guard !unique.isEmpty else { continue }
            result.append(LiveChannel(
                name: name,
                group: nonEmpty(LenientJSON.str(dict["group"])) ?? defaultGroup,
                urls: unique,
                logo: nonEmpty(LenientJSON.str(dict["logo"])),
                tvgID: nonEmpty(LenientJSON.str(dict["tvg-id"]))
                    ?? nonEmpty(LenientJSON.str(dict["tvgID"]))
            ))
        }
        return result
    }

    private static func resolveLiveURL(_ raw: String, against configURL: String?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 复用 spider 地址解析：剥 ";md5;…" 校验后缀 + 相对配置 URL 解析
        return resolveSpiderURL(trimmed, against: configURL) ?? trimmed
    }

    private static func defaultName(for url: String, index: Int) -> String {
        if let last = URL(string: url)?.lastPathComponent, !last.isEmpty, last != "/" {
            let stem = (last as NSString).deletingPathExtension
            if !stem.isEmpty { return stem }
        }
        return "直播源 \(index + 1)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

public struct LiveChannel: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var group: String
    /// 同一频道的多条线路（txt/m3u 里的 url1#url2#…）；播放失败依次回退
    public var urls: [String]
    public var logo: String?
    public var tvgID: String?
    /// 逐频道请求头（m3u 的 #EXTVLCOPT）：键用规范写法 "User-Agent" / "Referer"
    public var headers: [String: String]

    /// 同一分组内频道名唯一（解析时已合并重名）
    public var id: String { "\(group)#\(name)" }

    public init(name: String, group: String, urls: [String],
                logo: String? = nil, tvgID: String? = nil,
                headers: [String: String] = [:]) {
        self.name = name
        self.group = group
        self.urls = urls
        self.logo = logo
        self.tvgID = tvgID
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey {
        case name, group, urls, url, logo, tvgID, headers
    }

    /// 宽容解码：老配置的内联频道没有 headers（甚至没有 group）也不能抛错
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "未分类"
        if let list = try container.decodeIfPresent([String].self, forKey: .urls) {
            urls = list
        } else if let joined = try container.decodeIfPresent(String.self, forKey: .urls) {
            urls = joined.components(separatedBy: "#")
        } else if let single = try container.decodeIfPresent(String.self, forKey: .url) {
            urls = [single]
        } else {
            urls = []
        }
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        tvgID = try container.decodeIfPresent(String.self, forKey: .tvgID)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(group, forKey: .group)
        try container.encode(urls, forKey: .urls)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(tvgID, forKey: .tvgID)
        try container.encode(headers, forKey: .headers)
    }

    // Dictionary 不是 Hashable，这里手写 == / hash（headers 参与比较，键排序保证稳定）
    public static func == (lhs: LiveChannel, rhs: LiveChannel) -> Bool {
        lhs.name == rhs.name && lhs.group == rhs.group && lhs.urls == rhs.urls
            && lhs.logo == rhs.logo && lhs.tvgID == rhs.tvgID && lhs.headers == rhs.headers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(group)
        hasher.combine(urls)
        hasher.combine(logo)
        hasher.combine(tvgID)
        for key in headers.keys.sorted() {
            hasher.combine(key)
            hasher.combine(headers[key])
        }
    }
}

public struct LiveGenre: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var channels: [LiveChannel]

    public var id: String { name }

    public init(name: String, channels: [LiveChannel]) {
        self.name = name
        self.channels = channels
    }
}

public enum LiveError: LocalizedError, Sendable {
    case unsupportedSource(String)
    case requestFailed(String, String)
    case undecodable(String)
    case noChannels(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource(let name):
            return "「\(name)」不是在线 m3u/txt 直播源，当前版本不支持"
        case .requestFailed(let name, let detail):
            return "「\(name)」频道列表拉取失败：\(detail)"
        case .undecodable(let name):
            return "「\(name)」频道列表不是可识别的文本（编码不支持）"
        case .noChannels(let name):
            return "「\(name)」里没有解析到任何频道（不是 m3u/txt 频道列表，或内容为空）"
        }
    }
}
