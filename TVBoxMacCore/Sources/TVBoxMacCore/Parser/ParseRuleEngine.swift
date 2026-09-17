// ParseRuleEngine.swift — 播放地址二次解析（parse 规则）
import Foundation

/// TVBox 的 parse 规则：
///   type==0（直接拼接）：rule.url 是模板，把 {url}/{play_url} 占位替换为原播放地址
///   type==1（JSON 解析）：把播放地址发给 rule.url（ext 非空时 base64url 编码后拼 cat_ext 参数，
///       与安卓 ParseBean.mixUrl 一致），从响应 JSON 里按点路径取真实播放地址
public actor ParseRuleEngine {
    private let http: HTTPFetching

    public init(http: HTTPFetching = HttpClient()) {
        self.http = http
    }

    /// 返回可直接播放的 URL（m3u8/mp4/或带鉴权参数的地址）
    public func resolve(url: String, rule: ParseRule?,
                        siteHeader: [String: String] = [:],
                        globalHeader: [String: String] = [:],
                        ua: String = HTTPDefaults.defaultUA) async throws -> String {
        guard let rule, !rule.url.isEmpty else { return url }

        var merged = globalHeader
        for (k, v) in siteHeader { merged[k] = v }
        if let rh = rule.header, !rh.isEmpty,
           let data = rh.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in dict { merged[k] = "\(v)" }
        }
        merged["User-Agent"] = merged["User-Agent"] ?? ua

        if rule.type == 0 {
            return Self.concatTemplate(rule.url, url: url)
        }

        // type==1：JSON 解析
        let target = Self.buildParseUrl(rule.url, ext: rule.ext)
        guard let base = URL(string: target) else { throw HTTPClientError.badURL(target) }

        let data: Data
        if let client = http as? HttpClient {
            // POST JSON body {"url": ...}（TVBox 标准）
            let body = (try? JSONSerialization.data(withJSONObject: ["url": url])) ?? Data()
            let (d, _) = try await client.post(base, body: body, headers: merged)
            data = d
        } else {
            // 注入的 mock 只有 get → GET &url=...
            let sep = target.contains("?") ? "&" : "?"
            let enc = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
            let (d, _) = try await http.get(URL(string: target + sep + "url=" + enc)!, headers: merged)
            data = d
        }

        return try Self.extractPlayUrl(from: data, ext: rule.ext)
    }

    // MARK: - 模板拼接
    static func concatTemplate(_ template: String, url: String) -> String {
        if template.contains("{") {
            var out = template
            out = out.replacingOccurrences(of: "{url}", with: url)
            out = out.replacingOccurrences(of: "{play_url}", with: url)
            out = out.replacingOccurrences(of: "{playUrl}", with: url)
            return out
        }
        // 无占位符 → 拼在后面
        let sep: String
        if template.contains("?") { sep = "&" }
        else if template.hasSuffix("/") { sep = "" }
        else { sep = "/" }
        return template + sep + url
    }

    /// ext 非空 → base64url(ext JSON) 拼 cat_ext 参数（与安卓 ParseBean.mixUrl 一致）
    static func buildParseUrl(_ url: String, ext: JSONValue?) -> String {
        guard let ext, case .object(let dict) = ext, !dict.isEmpty else {
            return url
        }
        let native = dict.mapValues { $0.asAny }
        guard let data = try? JSONSerialization.data(withJSONObject: native) else {
            return url
        }
        let raw = String(decoding: data, as: UTF8.self)
        let b64url = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let sep = url.contains("?") ? "&" : "?"
        return url + sep + "cat_ext=" + b64url
    }

    /// 从 parse 响应里提取真实播放地址
    static func extractPlayUrl(from data: Data, ext: JSONValue?) throws -> String {
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.lowercased().hasPrefix("http") {
            return text
        }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) }
        catch { throw HTTPClientError.jsonParse("parse 响应不是 JSON") }

        // 1) ext 显式指定字段（"parse": "data.url"）
        if let path = ext?.value(at: "parse")?.stringValue ?? ext?.value(at: "key")?.stringValue,
           let hit = jsonPath(obj, path), let s = asString(hit),
           s.lowercased().hasPrefix("http") {
            return s
        }
        // 2) 常见字段探测
        for path in ["url", "data.url", "data", "video_info.url", "url_info.url"] {
            if let s = asString(jsonPath(obj, path)), s.lowercased().hasPrefix("http") {
                return s
            }
        }
        throw HTTPClientError.jsonParse("parse 响应里找不到播放地址")
    }

    static func jsonPath(_ obj: Any, _ path: String) -> Any? {
        var cur: Any = obj
        for seg in path.split(separator: ".").map(String.init) where seg != "$" {
            if let dict = cur as? [String: Any] {
                guard let next = dict[seg] else { return nil }
                cur = next
            } else if let arr = cur as? [Any], let i = Int(seg) {
                guard i < arr.count else { return nil }
                cur = arr[i]
            } else {
                return nil
            }
        }
        return cur
    }

    static func asString(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
}
