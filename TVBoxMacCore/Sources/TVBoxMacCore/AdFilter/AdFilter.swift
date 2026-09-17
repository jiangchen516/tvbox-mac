// AdFilter.swift — 去广告（m3u8 广告行 / url 广告参数）
import Foundation

/// 参考安卓 AdBlocker 的简化实现：
///  - m3u8 文本：删广告相关行（#EXTVLCOPT、广告标记、"广告"字样行）
///  - URL：清理 # 尾缀广告段、已知广告参数
public struct AdFilter: Sendable {
    public init() {}

    /// 统一入口：content 可能是 m3u8 文本或 URL
    public func apply(to content: String, rules: [String: JSONValue]? = nil) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http") {
            return Self.filterUrl(trimmed)
        }
        if trimmed.contains("#EXTM3U") || trimmed.contains("#EXTINF") {
            return Self.filterM3u8(trimmed)
        }
        return content
    }

    // MARK: - m3u8
    public static func filterM3u8(_ m3u8: String) -> String {
        var out: [String] = []
        var lastWasInf = false
        var skipNextUrl = false
        for rawLine in m3u8.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()

            // 广告行特征
            if line.hasPrefix("#") {
                if lower.hasPrefix("#extvlcopt") { continue }
                if lower.contains("http-referrer") { continue }
                if lower.hasPrefix("#ext-x-ad") { continue }
                if lower.contains("广告") { skipNextUrl = true; continue }  // 含"广告"的注释/EXTINF 行（含广告频道）
                out.append(rawLine)
                lastWasInf = lower.hasPrefix("#extinf")
                continue
            }

            // URL 行
            if isAdMarker(line) { skipNextUrl = false; continue }
            if skipNextUrl { skipNextUrl = false; continue }
            if lastWasInf {
                // 紧跟 #EXTINF 的 url：清理广告参数（adurl= 等）
                out.append(filterUrl(line))
            } else {
                out.append(rawLine)
            }
            lastWasInf = false
        }
        return out.joined(separator: "\n")
    }

    static func isAdMarker(_ line: String) -> Bool {
        // 只匹配"广告域名/路径"的整行（去掉 query 再判断，避免误杀带 adurl 参数的正常 URL）
        let base = line.split(separator: "?").first.map(String.init) ?? line
        let lower = base.lowercased()
        return lower.contains(".ad.") || lower.contains("//ad.")
    }

    // MARK: - URL 清理
    public static func filterUrl(_ url: String) -> String {
        var out = url
        // 去掉 #广告段 尾缀
        if let hashIdx = out.firstIndex(of: "#") {
            let after = out[out.index(after: hashIdx)...]
            if isAdTail(String(after)) {
                out = String(out[..<hashIdx])
            }
        }
        // 清理已知广告参数
        if var comps = URLComponents(string: out) {
            var items = comps.queryItems ?? []
            items.removeAll { isAdParam($0.name) }
            if !items.isEmpty {
                comps.queryItems = items
            } else {
                comps.query = nil
            }
            if let cleaned = comps.url?.absoluteString {
                out = cleaned
            }
        }
        return out
    }

    static func cleanUrl(_ url: String) -> String? {
        var out = url
        if let hashIdx = out.firstIndex(of: "#") {
            let after = String(out[out.index(after: hashIdx)...])
            if isAdTail(after) { out = String(out[..<hashIdx]) }
        }
        return out
    }

    static func isAdTail(_ tail: String) -> Bool {
        let lower = tail.lowercased()
        return lower.contains("广告") || lower.hasPrefix("ad") || lower.contains("adurl")
    }

    static func isAdParam(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("adurl") || lower.hasPrefix("adflag") || lower.hasPrefix("ad_tag") { return true }
        if lower == "ad" || lower == "adv" { return true }
        return false
    }
}
