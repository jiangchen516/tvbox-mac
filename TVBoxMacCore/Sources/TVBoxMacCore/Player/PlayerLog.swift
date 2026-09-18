// PlayerLog.swift — 播放诊断日志（缓冲慢/加载失败排查用）
// 写到 App Support/TVBoxMac/player.log（同时 NSLog 进 Console.app），
// 超过 512KB 自动截断保留尾部 ~256KB
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum PlayerLog {
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static var fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("player.log")
    }()

    public static func append(_ line: String) {
        let entry = "[\(isoFormatter.string(from: Date()))] \(line)\n"
        NSLog("[PlayerLog] \(line)")
        if let fh = FileHandle(forWritingAtPath: fileURL.path) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(Data(entry.utf8))
        } else {
            try? entry.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        rotateIfNeeded()
    }

    static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64, size > 512_000,
              let data = try? Data(contentsOf: fileURL) else { return }
        try? data.suffix(256_000).write(to: fileURL, options: .atomic)
    }

    #if canImport(AVFoundation)
    /// 读 access log 最新一条（uri/码率/分段下载量）——字段经 KVC（见 readNetworkSpeed 注释）
    static func accessEntrySummary(_ item: AVPlayerItem) -> String {
        guard let log = item.value(forKey: "accessLog") as? NSObject,
              let events = log.value(forKey: "events") as? [Any],
              let e = events.last as? NSObject else { return "access log 不可读" }
        let uri = (e.value(forKey: "uri") as? String) ?? "-"
        let bitrate = (e.value(forKey: "observedBitrate") as? Double) ?? 0
        let segDur = (e.value(forKey: "segmentsDownloadedDuration") as? Double) ?? 0
        let segBytes = (e.value(forKey: "segmentsDownloadedBytes") as? Double) ?? 0
        let reqs = (e.value(forKey: "numberOfMediaRequests") as? Int) ?? 0
        let stall = (e.value(forKey: "numberOfStalls") as? Int) ?? 0
        return "uri=\(uri.prefix(110)) 码率=\(Int(bitrate / 1024))Kbps 分段=\(Int(segDur))s/\(Int(segBytes / 1024))KB 请求=\(reqs) 停顿=\(stall)"
    }

    /// 读 error log 最新一条（加载环节的具体错误）
    static func errorEntrySummary(_ item: AVPlayerItem) -> String {
        guard let log = item.value(forKey: "errorLog") as? NSObject,
              let events = log.value(forKey: "errorLogEvents") as? [Any]
                  ?? log.value(forKey: "events") as? [Any],
              let e = events.last as? NSObject else { return "error log 不可读" }
        let domain = (e.value(forKey: "errorDomain") as? String) ?? "-"
        let code = (e.value(forKey: "errorStatusCode") as? Int) ?? -1
        let comment = (e.value(forKey: "errorComment") as? String) ?? "-"
        let uri = (e.value(forKey: "uri") as? String) ?? "-"
        return "❌ uri=\(uri.prefix(110)) [\(domain) code=\(code)] \(comment)"
    }
    #else
    static func accessEntrySummary(_: AnyObject) -> String { "-" }
    static func errorEntrySummary(_: AnyObject) -> String { "-" }
    #endif
}
