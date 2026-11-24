// StreamPreflight.swift — 播放前预检（面向 Bridge 本地代理地址）
//
// csp_/jar 源播放时，Bridge 有时把「一条上游直链」当播放列表返回；AVPlayer 既播不了
// 也不会立刻报错，只能等 12 秒兜底。预检在交给 AVPlayer 前先取一次：
//   - 是 #EXTM3U → 原地址可用；
//   - 是单条 http(s) 直链 → 跟着探一次，2xx 就改用直链；
//   - 4xx/5xx、抓不到、内容不是播放列表 → 立即判无效，走换线路。
// 只对 127.0.0.1/localhost 的 /proxy/ 地址生效，普通直链不额外请求。
import Foundation

public enum StreamPreflightError: LocalizedError, Sendable {
    case httpStatus(Int)
    case deadUpstream(String)
    case notPlaylist(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "播放地址返回 HTTP \(code)"
        case .deadUpstream(let host): return "线路直链无法访问（\(host)）"
        case .notPlaylist(let detail): return "播放地址不是 HLS 播放列表：\(detail)"
        }
    }
}

public struct StreamPreflight: Sendable {
    private let http: HTTPFetching
    private let probeBytes: Int

    public init(http: HTTPFetching = HttpClient(), probeBytes: Int = 1024) {
        self.http = http
        self.probeBytes = probeBytes
    }

    /// 返回可直接交给 AVPlayer 的地址；非 Bridge 代理地址原样返回（不发请求）。
    public func prepare(_ url: URL, headers: [String: String]) async throws -> URL {
        guard Self.isBridgeProxy(url) else { return url }
        let (data, response) = try await probe(url, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            throw StreamPreflightError.httpStatus(response.statusCode)
        }
        let text = Self.textPrefix(data)
        if text.hasPrefix("#EXT") { return url }
        if let upstream = Self.singleURL(in: text) {
            do {
                let (_, upstreamResponse) = try await probe(upstream, headers: headers)
                guard (200..<300).contains(upstreamResponse.statusCode) else {
                    throw StreamPreflightError.httpStatus(upstreamResponse.statusCode)
                }
            } catch let error as StreamPreflightError {
                throw error
            } catch {
                throw StreamPreflightError.deadUpstream(upstream.host ?? "上游")
            }
            return upstream
        }
        throw StreamPreflightError.notPlaylist("代理返回 \(data.count) 字节的非播放列表内容")
    }

    private func probe(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPResponse) {
        var requestHeaders = headers
        requestHeaders["Range"] = "bytes=0-\(probeBytes - 1)"
        return try await http.get(url, headers: requestHeaders)
    }

    static func isBridgeProxy(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        return loopback && url.path.contains("/proxy/")
    }

    static func textPrefix(_ data: Data) -> String {
        String(data: data.prefix(4096), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func singleURL(in text: String) -> URL? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, let first = lines.first,
              first.lowercased().hasPrefix("http") else { return nil }
        return URL(string: first)
    }
}
