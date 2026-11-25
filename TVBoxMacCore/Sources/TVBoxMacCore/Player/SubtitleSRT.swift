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
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
