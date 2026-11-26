// DownloadManager.swift — 点播下载（mp4 直下 / 未加密 HLS 转本地播放列表）
//
// 限制：加密 HLS、fMP4（#EXT-X-MAP）暂不支持；下载的是原始流，不做转码。
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DownloadResult: Sendable {
    public let url: URL
    public let isPlaylist: Bool

    public init(url: URL, isPlaylist: Bool) {
        self.url = url
        self.isPlaylist = isPlaylist
    }
}

public enum DownloadError: LocalizedError, Sendable {
    case unsupported(String)
    case httpStatus(Int)
    case encryptedHLS
    case fMP4Unsupported
    case emptyPlaylist

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what): return "暂不支持下载：\(what)"
        case .httpStatus(let code): return "下载失败：HTTP \(code)"
        case .encryptedHLS: return "该 HLS 流是加密的，暂不支持下载"
        case .fMP4Unsupported: return "该 HLS 是 fMP4 分片，暂不支持下载"
        case .emptyPlaylist: return "播放列表里没有分片"
        }
    }
}

public actor DownloadManager {
    private let directory: URL
    private let session: URLSession

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMac", isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration)
    }

    public func download(mediaURL: URL, headers: [String: String], title: String) async throws -> DownloadResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = Self.sanitize(title)
        let isHLS = mediaURL.path.lowercased().contains(".m3u8")
            || mediaURL.absoluteString.lowercased().contains(".m3u8?")
        if isHLS {
            return try await downloadHLS(mediaURL, headers: headers, safe: safe)
        }
        let (temp, response) = try await session.download(for: Self.request(mediaURL, headers: headers))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let ext = mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension
        let dest = directory.appendingPathComponent("\(safe).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return DownloadResult(url: dest, isPlaylist: false)
    }

    private func downloadHLS(_ url: URL, headers: [String: String], safe: String) async throws -> DownloadResult {
        var playlistURL = url
        var text = try await fetchText(url, headers: headers)
        if let variant = Self.bestVariant(in: text, base: url) {
            PlayerLog.append("⬇️ HLS 选择最高码率分片列表")
            playlistURL = variant
            text = try await fetchText(variant, headers: headers)
        }
        if text.contains("#EXT-X-MAP") { throw DownloadError.fMP4Unsupported }
        if Self.isEncrypted(text) { throw DownloadError.encryptedHLS }
        let segments = try Self.parseMediaPlaylist(text, base: playlistURL)
        guard !segments.isEmpty else { throw DownloadError.emptyPlaylist }

        let folder = directory.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(ceil(segments.map(\.duration).max() ?? 10)))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        for (index, segment) in segments.enumerated() {
            let name = String(format: "seg%05d.ts", index)
            let (temp, response) = try await session.download(for: Self.request(segment.url, headers: headers))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try FileManager.default.moveItem(at: temp, to: folder.appendingPathComponent(name))
            lines.append("#EXTINF:\(segment.duration),")
            lines.append(name)
            if index % 20 == 0 || index == segments.count - 1 {
                PlayerLog.append("⬇️ HLS 分片 \(index + 1)/\(segments.count)")
            }
        }
        lines.append("#EXT-X-ENDLIST")
        let local = folder.appendingPathComponent("index.m3u8")
        try lines.joined(separator: "\n").write(to: local, atomically: true, encoding: .utf8)
        return DownloadResult(url: local, isPlaylist: true)
    }

    // MARK: - 播放列表解析（静态，单测覆盖）

    static func bestVariant(in text: String, base: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = Self.bandwidth(in: line) ?? 0
                var next = index + 1
                while next < lines.count {
                    let candidate = lines[next].trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty, !candidate.hasPrefix("#") {
                        if let url = URL(string: candidate, relativeTo: base)?.absoluteURL,
                           best == nil || bandwidth > best!.bandwidth {
                            best = (bandwidth, url)
                        }
                        break
                    }
                    next += 1
                }
            }
            index += 1
        }
        return best?.url
    }

    static func bandwidth(in line: String) -> Int? {
        guard let range = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression) else { return nil }
        return Int(line[range].dropFirst("BANDWIDTH=".count))
    }

    static func isEncrypted(_ text: String) -> Bool {
        text.range(of: #"#EXT-X-KEY:METHOD=(?!NONE)"#, options: .regularExpression) != nil
    }

    static func parseMediaPlaylist(_ text: String, base: URL) throws -> [(url: URL, duration: Double)] {
        var out: [(URL, Double)] = []
        var pending: Double?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count)
                    .split(separator: ",").first.map(String.init) ?? ""
                pending = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let duration = pending else { continue }
            if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                out.append((url, duration))
            }
            pending = nil
        }
        return out
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : String(cleaned.prefix(120))
    }

    private func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        let (data, response) = try await session.data(for: Self.request(url, headers: headers))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
}
