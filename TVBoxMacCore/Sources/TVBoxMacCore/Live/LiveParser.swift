// LiveParser.swift — 直播播放列表解析（txt / m3u）+ 文本解码
//
// 支持 TVBox 生态里最常见的两种频道列表：
// 1. txt：
//      央视,#genre#
//      CCTV-1 综合,http://…/a.m3u8#http://…/b.m3u8
//    频道行格式 "频道名,url1#url2"，url 用 # 分隔多线路；",#genre#" 行表示分组。
// 2. m3u：
//      #EXTM3U
//      #EXTINF:-1 tvg-id="cctv1" tvg-logo="…" group-title="央视",CCTV-1 综合
//      http://…/a.m3u8
//
// 真实源很脏：CRLF、BOM、空行、注释、重名频道、URL 缺失、GBK 编码、偶尔整个
// 列表被 base64 包一层。全部按"能解析就解析，解析不出就跳过"处理。
import Foundation
import CoreFoundation

public enum LiveParser {
    /// 把已解析的频道按分组整理（内联频道 / 单测用）
    public static func group(_ channels: [LiveChannel]) -> [LiveGenre] {
        var builder = GenreBuilder()
        for channel in channels { builder.add(channel) }
        return builder.result
    }

    /// 自动识别 txt / m3u 并解析；空文本返回 []
    public static func parse(_ text: String) -> [LiveGenre] {
        let normalized = normalizeNewlines(text)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let upper = trimmed.uppercased()
        if upper.hasPrefix("#EXTM3U") || upper.contains("#EXTINF") {
            return parseM3U(normalized)
        }
        return parseTXT(normalized)
    }

    // MARK: - txt

    public static func parseTXT(_ text: String) -> [LiveGenre] {
        var builder = GenreBuilder()
        var currentGroup = ""

        for rawLine in normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let comma = line.firstIndex(of: ",") else { continue }

            let rawName = line[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawRest = line[line.index(after: comma)...].trimmingCharacters(in: .whitespacesAndNewlines)

            // 分组标记： 央视,#genre#
            if rawRest.lowercased().contains("#genre#") {
                currentGroup = rawName
                continue
            }

            guard !rawName.isEmpty else { continue }
            let urls = rawRest
                .split(separator: "#", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            guard !urls.isEmpty else { continue }

            builder.add(LiveChannel(name: rawName,
                                    group: currentGroup.isEmpty ? "未分类" : currentGroup,
                                    urls: urls))
        }
        return builder.result
    }

    // MARK: - m3u

    public static func parseM3U(_ text: String) -> [LiveGenre] {
        var builder = GenreBuilder()
        var pending: (name: String, group: String, logo: String?, tvgID: String?)?

        for rawLine in normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.uppercased().hasPrefix("#EXTINF") {
                let attrs = attributes(in: line)
                let name = m3uName(from: line, attrs: attrs)
                guard !name.isEmpty else { continue }
                let group = attrs["group-title"].flatMap { nonEmpty($0) } ?? "未分类"
                pending = (name, group,
                           attrs["tvg-logo"].flatMap { nonEmpty($0) },
                           attrs["tvg-id"].flatMap { nonEmpty($0) })
                continue
            }
            if line.hasPrefix("#") { continue }   // #EXTM3U / #EXTVLCOPT / 注释

            guard let entry = pending else { continue }
            let url = line
            guard !url.isEmpty else { continue }
            builder.add(LiveChannel(name: entry.name, group: entry.group, urls: [url],
                                    logo: entry.logo, tvgID: entry.tvgID))
            pending = nil
        }
        return builder.result
    }

    /// 解析 #EXTINF 行里的 key="value" 属性（大小写不敏感取键）
    static func attributes(in line: String) -> [String: String] {
        var out: [String: String] = [:]
        var rest = line[...]
        while let eq = rest.firstIndex(of: "=") {
            let key = rest[..<eq]
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .last
                .map(String.init) ?? ""
            var after = rest[rest.index(after: eq)...]
            guard after.first == "\"" else {
                rest = after   // 不是 "k=v"（例如 URL 里的 =），继续往后找
                continue
            }
            after = after.dropFirst()
            guard let close = after.firstIndex(of: "\"") else { break }
            let value = String(after[..<close])
            if !key.isEmpty { out[key.lowercased()] = value }
            rest = after[after.index(after: close)...]
        }
        return out
    }

    /// 显示名称：属性后面的 ",名称"（名称自身可含逗号）；没有属性时取第一个逗号之后
    static func m3uName(from line: String, attrs: [String: String]) -> String {
        var tail: Substring
        if let lastQuote = line.lastIndex(of: "\"") {
            tail = line[line.index(after: lastQuote)...]
        } else if let colon = line.firstIndex(of: ":") {
            tail = line[line.index(after: colon)...]
        } else {
            tail = line[...]
        }
        if let comma = tail.firstIndex(of: ",") {
            let name = tail[tail.index(after: comma)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if let tvgName = nonEmpty(attrs["tvg-name"] ?? "") { return tvgName }
        return ""
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")   // BOM
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 有序分组构造器：保持列表顺序，同组同频道合并线路（真实源常把同一频道拆成多行）
private struct GenreBuilder {
    private var genres: [LiveGenre] = []
    private var index: [String: Int] = [:]

    mutating func add(_ channel: LiveChannel) {
        guard let genreIndex = index[channel.group] else {
            index[channel.group] = genres.count
            genres.append(LiveGenre(name: channel.group, channels: [channel]))
            return
        }
        guard let channelIndex = genres[genreIndex].channels.firstIndex(where: { $0.name == channel.name }) else {
            genres[genreIndex].channels.append(channel)
            return
        }
        var existing = genres[genreIndex].channels[channelIndex]
        for url in channel.urls where !existing.urls.contains(url) {
            existing.urls.append(url)
        }
        if existing.logo == nil { existing.logo = channel.logo }
        if existing.tvgID == nil { existing.tvgID = channel.tvgID }
        genres[genreIndex].channels[channelIndex] = existing
    }

    var result: [LiveGenre] {
        genres.filter { !$0.channels.isEmpty }
    }
}

// MARK: - 文本解码

public enum LiveTextDecoder {
    /// 数据 → 文本：UTF-8 优先，失败回退 GB18030（国内 IPTV 列表常见），再退 Latin-1
    public static func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let gb = decodeGB18030(data) { return gb }
        return String(data: data, encoding: .isoLatin1)
    }

    /// 频道列表文本：处理"整个列表被 base64 包一层"的源
    public static func playlistText(from data: Data) -> String? {
        guard let text = decode(data) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // 正常 txt 一定有逗号；正常 m3u 以 #EXTM3U 开头
        if trimmed.uppercased().hasPrefix("#EXTM3U") || trimmed.contains(",") { return text }

        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 24,
              compact.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil,
              let decodedData = Data(base64Encoded: compact),
              let inner = decode(decodedData) else { return text }
        let innerTrimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if innerTrimmed.uppercased().hasPrefix("#EXTM3U") || innerTrimmed.contains(",") {
            return inner
        }
        return text
    }

    static func decodeGB18030(_ data: Data) -> String? {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: cf))
    }
}
