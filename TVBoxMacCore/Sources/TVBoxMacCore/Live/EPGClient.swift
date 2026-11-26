// EPGClient.swift — 直播节目单（按频道 + 日期查询的 JSON EPG）
//
// 配置里的 lives[].epg 常见形态是模板 URL：
//   https://…/api?ch={NAME}&date=YYYY-MM-DD
// 返回：{"channel_name":"…","date":"…","epg_data":[{"start":"20:00","end":"21:00","title":"…"}]}
// 时间是北京时间（频道作息按北京时区），这里统一换算成 Date；显示端用本地时区。
import Foundation

public struct EPGProgram: Sendable, Equatable, Identifiable {
    public let channel: String
    public let title: String
    public let start: Date
    public let end: Date

    public var id: String { "\(channel)#\(Int(start.timeIntervalSince1970))" }

    public init(channel: String, title: String, start: Date, end: Date) {
        self.channel = channel
        self.title = title
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool { start <= date && date < end }
}

public enum EPGError: LocalizedError, Sendable {
    case badTemplate
    case httpStatus(Int)
    case undecodable
    case empty

    public var errorDescription: String? {
        switch self {
        case .badTemplate: return "EPG 地址模板无效"
        case .httpStatus(let code): return "EPG 请求失败：HTTP \(code)"
        case .undecodable: return "EPG 响应不是可识别的 JSON"
        case .empty: return "EPG 没有节目数据"
        }
    }
}

public actor EPGClient {
    public static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private struct CacheEntry {
        let programs: [EPGProgram]
        let storedAt: Date
    }

    private let http: HTTPFetching
    private let cacheTTL: TimeInterval
    private let maxBytes: Int
    private var cache: [String: CacheEntry] = [:]

    public init(http: HTTPFetching = HttpClient(),
                cacheTTL: TimeInterval = 6 * 3600,
                maxBytes: Int = 4 * 1024 * 1024) {
        self.http = http
        self.cacheTTL = cacheTTL
        self.maxBytes = maxBytes
    }

    /// 某频道某天（北京时间）的节目。
    public func programs(channel: String, template: String, day: Date,
                         headers: [String: String] = [:]) async throws -> [EPGProgram] {
        let url = try Self.makeURL(template: template, channel: channel, day: day)
        let key = url.absoluteString
        if let hit = cache[key], Date().timeIntervalSince(hit.storedAt) < cacheTTL {
            return hit.programs
        }
        let (data, response) = try await http.get(url, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            throw EPGError.httpStatus(response.statusCode)
        }
        guard data.count <= maxBytes else { throw EPGError.empty }
        let parsed = try Self.decode(data: data, channel: channel, day: day)
        cache[key] = CacheEntry(programs: parsed, storedAt: .now)
        return parsed
    }

    /// 从 from 起未来 hours 小时的节目（跨天自动补查下一天）。
    public func schedule(channel: String, template: String, from: Date = .now,
                         hours: Int = 12, headers: [String: String] = [:]) async throws -> [EPGProgram] {
        guard hours > 0 else { return [] }
        let limit = from.addingTimeInterval(TimeInterval(hours) * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.beijingTimeZone
        var dayStart = calendar.startOfDay(for: from)
        var all: [EPGProgram] = []
        var dayCount = 0
        while dayStart < limit, dayCount < 3 {
            if let list = try? await programs(channel: channel, template: template,
                                              day: dayStart, headers: headers) {
                all.append(contentsOf: list)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = next
            dayCount += 1
        }
        var seen = Set<String>()
        return all
            .filter { $0.end > from && $0.start < limit }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: - URL / 解析

    static func makeURL(template: String, channel: String, day: Date) throws -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let encoded = channel.addingPercentEncoding(withAllowedCharacters: allowed) ?? channel
        var text = template
            .replacingOccurrences(of: "{NAME}", with: encoded)
            .replacingOccurrences(of: "{name}", with: encoded)
        guard var comps = URLComponents(string: text) else { throw EPGError.badTemplate }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "date" }
        items.append(URLQueryItem(name: "date", value: dayString(day)))
        if !template.contains("{NAME}") && !template.contains("{name}") {
            items.removeAll { $0.name == "ch" }
            items.append(URLQueryItem(name: "ch", value: channel))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw EPGError.badTemplate }
        return url
    }

    static func dayString(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = beijingTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    private struct Response: Decodable {
        let channel_name: String?
        let epg_data: [Item]?

        struct Item: Decodable {
            let start: String
            let end: String
            let title: String?
        }
    }

    static func decode(data: Data, channel: String, day: Date) throws -> [EPGProgram] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw EPGError.undecodable
        }
        guard let items = response.epg_data else { throw EPGError.empty }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        guard let dayStart = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: day) else {
            throw EPGError.empty
        }
        var out: [EPGProgram] = []
        for item in items {
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let startSec = seconds(item.start),
                  let endSec = seconds(item.end) else { continue }
            var endSeconds = endSec
            if endSeconds <= startSec { endSeconds += 24 * 3600 }   // 跨零点
            let startDate = dayStart.addingTimeInterval(TimeInterval(startSec))
            let endDate = dayStart.addingTimeInterval(TimeInterval(endSeconds))
            guard endDate > startDate else { continue }
            out.append(EPGProgram(channel: channel, title: title, start: startDate, end: endDate))
        }
        return out.sorted { $0.start < $1.start }
    }

    static func seconds(_ raw: String) -> Int? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .split(separator: ":")
            .compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)
    }
}


/// 频道名归一化：EPG 接口按名字查，源里的名字常带「高清/HD/频道」等后缀
public enum EPGChannelAliases {
    public static func candidates(for raw: String) -> [String] {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var out = [name]
        let collapsed = name.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        out.append(collapsed)
        if let cctv = cctvNumber(in: name) {
            out.append("CCTV-\(cctv)")
            out.append("CCTV\(cctv)")
        }
        var stem = collapsed
        for suffix in ["高清", "超清", "蓝光", "4K", "HD", "频道"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        if !stem.isEmpty, stem != collapsed { out.append(stem) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }.prefix(5).map { $0 }
    }

    /// EPG 接口会返回「精彩节目-暂未提供节目预告信息」占位条目
    public static func isPlaceholder(title: String) -> Bool {
        title.contains("暂未提供") || title.contains("免费使用") || title == "精彩节目"
    }

    private static func cctvNumber(in name: String) -> String? {
        guard let range = name.range(of: #"(?i)CCTV[-_ ]?(\d+)"#, options: .regularExpression) else { return nil }
        return String(name[range].drop(while: { !$0.isNumber }))
    }
}
