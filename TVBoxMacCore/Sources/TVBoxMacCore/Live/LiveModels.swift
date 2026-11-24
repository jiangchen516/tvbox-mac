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

    public var id: String { "\(name)|\(url)|\(group ?? "")" }

    public init(name: String, url: String, group: String? = nil, ua: String? = nil,
                header: String? = nil, epg: String? = nil, logo: String? = nil,
                playerType: String? = nil, type: Int = 0, ext: JSONValue? = nil) {
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
    }

    /// 是否是可抓取的在线播放列表（当前唯一支持的类型）
    public var isHTTPPlaylist: Bool {
        let low = url.lowercased()
        return low.hasPrefix("http://") || low.hasPrefix("https://")
    }

    /// 不能在当前版本播放时的原因（UI 直接展示）
    public var unsupportedReason: String? {
        if isHTTPPlaylist { return nil }
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
        } else if headers["User-Agent"] == nil {
            headers["User-Agent"] = HTTPDefaults.defaultUA
        }
        return headers
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
            let name = nonEmpty(LenientJSON.str(dict["name"]))
                ?? defaultName(for: url, index: index)
            return LiveSource(
                name: name,
                url: url,
                group: nonEmpty(LenientJSON.str(dict["group"])),
                ua: nonEmpty(LenientJSON.str(dict["ua"])),
                header: nonEmpty(LenientJSON.str(dict["header"])),
                epg: nonEmpty(LenientJSON.str(dict["epg"])),
                logo: nonEmpty(LenientJSON.str(dict["logo"])),
                playerType: nonEmpty(LenientJSON.str(dict["playerType"])),
                type: LenientJSON.int(dict["type"]) ?? 0,
                ext: dict["ext"]
            )
        default:
            return LiveSource(name: "直播源 \(index + 1)", url: "")
        }
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

    /// 同一分组内频道名唯一（解析时已合并重名）
    public var id: String { "\(group)#\(name)" }

    public init(name: String, group: String, urls: [String],
                logo: String? = nil, tvgID: String? = nil) {
        self.name = name
        self.group = group
        self.urls = urls
        self.logo = logo
        self.tvgID = tvgID
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
