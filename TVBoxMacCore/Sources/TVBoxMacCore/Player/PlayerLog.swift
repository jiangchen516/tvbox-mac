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

    /// Double → Int 安全转换：CMTime/KVC 取值可能是 infinite 或 NaN，
    /// 直接 Int(x) 会触发 Swift runtime trap（实测崩溃：stop() → replaceCurrentItem(nil)
    /// → timeControlStatus KVO → Int(player.currentTime().seconds) = Int(NaN)）
    public static func safeInt(_ d: Double) -> Int {
        guard d.isFinite else { return 0 }
        return Int(d)
    }

    /// app 启动标记：记录可执行文件路径与构建时间——排查「跑的是哪份包」
    public static func logAppLaunch() {
        let exe = Bundle.main.executableURL
        let built = (try? exe?.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let builtStr = built.map { fmt.string(from: $0) } ?? "未知"
        append("=== TVBoxMac 启动 | 二进制构建于 \(builtStr) | \(exe?.path ?? "路径未知") ===")
    }

    static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64, size > 512_000,
              let data = try? Data(contentsOf: fileURL) else { return }
        try? data.suffix(256_000).write(to: fileURL, options: .atomic)
    }

    #if canImport(AVFoundation)
    /// 安全 KVC 读取：键不存在时 KVC 抛 NSException（valueForUndefinedKey），
    /// Swift 无法 catch → 直接 abort（实测崩溃）。所有键必须先 responds(to:) 预检
    static func kv(_ obj: NSObject?, _ key: String) -> Any? {
        guard let obj, obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key)
    }

    /// 读 access log 最新一条（uri/码率/分段下载量）——字段经 KVC（见 readNetworkSpeed 注释）
    static func accessEntrySummary(_ item: AVPlayerItem) -> String {
        guard let log = kv(item, "accessLog") as? NSObject,
              let events = kv(log, "events") as? [Any],
              let e = events.last as? NSObject else { return "access log 不可读" }
        let uri = (kv(e, "uri") as? String) ?? "-"
        let bitrate = (kv(e, "observedBitrate") as? Double) ?? 0
        let segDur = (kv(e, "segmentsDownloadedDuration") as? Double) ?? 0
        let segBytes = (kv(e, "segmentsDownloadedBytes") as? Double) ?? 0
        let reqs = (kv(e, "numberOfMediaRequests") as? Int) ?? 0
        let stall = (kv(e, "numberOfStalls") as? Int) ?? 0
        return "uri=\(uri.prefix(110)) 码率=\(safeInt(bitrate / 1024))Kbps 分段=\(safeInt(segDur))s/\(safeInt(segBytes / 1024))KB 请求=\(reqs) 停顿=\(stall)"
    }

    /// 读 error log 最新一条（加载环节的具体错误）
    static func errorEntrySummary(_ item: AVPlayerItem) -> String {
        guard let log = kv(item, "errorLog") as? NSObject,
              let events = (kv(log, "events") as? [Any]),
              let e = events.last as? NSObject else { return "error log 不可读" }
        let domain = (kv(e, "errorDomain") as? String) ?? "-"
        let code = (kv(e, "errorStatusCode") as? Int) ?? -1
        let comment = (kv(e, "errorComment") as? String) ?? "-"
        let uri = (kv(e, "uri") as? String) ?? "-"
        return "❌ uri=\(uri.prefix(110)) [\(domain) code=\(code)] \(comment)"
    }
    #else
    static func kv(_ obj: AnyObject?, _ key: String) -> Any? { nil }
    static func accessEntrySummary(_: AnyObject) -> String { "-" }
    static func errorEntrySummary(_: AnyObject) -> String { "-" }
    #endif
}
