// SubtitleSRT.swift — 外挂 SRT 字幕解析（纯逻辑，可单测）
//
// 只做最常用的 SRT：编号行可有可无、时间轴 00:00:01,000 --> 00:00:04,000
// （逗号或点都接受）、多行文本、简单 HTML 标签剥离。解析不出来的块直接跳过。
import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SRTParser {
    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let arrow = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[arrow].components(separatedBy: "-->")
            guard times.count >= 2,
                  let start = parseTime(times[0]),
                  let end = parseTime(times[1]) else { continue }
            let body = lines[(arrow + 1)...]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: max(end, start),
                                    text: stripTags(body)))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// 当前播放时间对应的字幕（线性查找；字幕通常几千行，0.5s 一次足够）
    public static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        cues.first { time >= $0.start && time < $0.end }
    }

    static func parseTime(_ raw: String) -> Double? {
        // VTT 行尾可能带位置设置（align:start 等），只取时间本身
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .first?
            .replacingOccurrences(of: ",", with: ".")
            ?? ""
        let parts = cleaned.components(separatedBy: ":")
        // SRT: HH:MM:SS.mmm；VTT 允许 MM:SS.mmm
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        default:
            return nil
        }
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}


/// 字幕文本入口：按内容自动识别 WebVTT / SRT（源返回的字幕两种都有）
public enum SubtitleText {
    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let head = normalized.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if head.hasPrefix("WEBVTT") || head.contains("WEBVTT") {
            return parseVTT(normalized)
        }
        return SRTParser.parse(normalized)
    }

    static func parseVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // 跳过头部/注释/样式块
            if let first = lines.first(where: { !$0.isEmpty }),
               first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") ||
               first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                continue
            }
            guard let arrow = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[arrow].components(separatedBy: "-->")
            guard times.count >= 2,
                  let start = SRTParser.parseTime(times[0]),
                  let end = SRTParser.parseTime(times[1]) else { continue }
            let body = lines[(arrow + 1)...]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: max(end, start),
                                    text: SRTParser.stripTags(body)))
        }
        return cues.sorted { $0.start < $1.start }
    }
}

/// 在线字幕下载 + 解析（源内置字幕 / 后续手动搜索共用）
public enum SubtitleLoadError: LocalizedError, Sendable {
    case httpStatus(Int)
    case undecodable
    case empty

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "字幕下载失败：HTTP \(code)"
        case .undecodable: return "字幕文件编码不支持"
        case .empty: return "字幕文件里没有解析到内容（可能不是 SRT/VTT）"
        }
    }
}

public struct SubtitleLoader: Sendable {
    private let http: HTTPFetching

    public init(http: HTTPFetching = HttpClient()) {
        self.http = http
    }

    public func cues(from url: URL, headers: [String: String] = [:]) async throws -> [SubtitleCue] {
        let (data, response) = try await http.get(url, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            throw SubtitleLoadError.httpStatus(response.statusCode)
        }
        guard let text = LiveTextDecoder.decode(data) else { throw SubtitleLoadError.undecodable }
        let cues = SubtitleText.parse(text)
        guard !cues.isEmpty else { throw SubtitleLoadError.empty }
        return cues
    }
}
