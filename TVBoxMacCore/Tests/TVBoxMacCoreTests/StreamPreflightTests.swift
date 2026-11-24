// StreamPreflightTests.swift — 代理播放地址预检（全离线）
import XCTest
@testable import TVBoxMacCore

private struct ClosureHTTP: HTTPFetching {
    let handler: @Sendable (URL) async throws -> (Data, HTTPResponse)

    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        try await handler(url)
    }
}

final class StreamPreflightTests: XCTestCase {
    private let proxy = URL(string: "http://127.0.0.1:19978/proxy/media/abc")!

    func testNonProxyURLPassesThroughWithoutRequest() async throws {
        let http = ClosureHTTP { _ in
            XCTFail("普通直链不应触发预检请求")
            throw URLError(.badURL)
        }
        let preflight = StreamPreflight(http: http)
        let url = URL(string: "https://example.com/a.m3u8")!
        let result = try await preflight.prepare(url, headers: [:])
        XCTAssertEqual(result, url)
    }

    func testProxyPlaylistPassesThrough() async throws {
        let http = ClosureHTTP { _ in
            (Data("#EXTM3U\n#EXTINF:3,\nhttp://example.com/a.ts\n".utf8),
             HTTPResponse(url: nil, statusCode: 200))
        }
        let result = try await StreamPreflight(http: http).prepare(proxy, headers: [:])
        XCTAssertEqual(result, proxy)
    }

    func testProxyBareURLFallsBackToUpstream() async throws {
        let upstream = URL(string: "https://up.example/a.m3u8")!
        let http = ClosureHTTP { url in
            if url == upstream {
                return (Data("#EXTM3U\n".utf8), HTTPResponse(url: url, statusCode: 200))
            }
            return (Data(upstream.absoluteString.utf8), HTTPResponse(url: url, statusCode: 200))
        }
        let result = try await StreamPreflight(http: http).prepare(proxy, headers: [:])
        XCTAssertEqual(result, upstream)
    }

    func testProxy403Throws() async {
        let http = ClosureHTTP { url in (Data(), HTTPResponse(url: url, statusCode: 403)) }
        do {
            _ = try await StreamPreflight(http: http).prepare(proxy, headers: [:])
            XCTFail("应报 HTTP 403")
        } catch let error as StreamPreflightError {
            guard case .httpStatus(403) = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testProxyHTMLThrowsNotPlaylist() async {
        let http = ClosureHTTP { url in
            (Data("<html>blocked</html>".utf8), HTTPResponse(url: url, statusCode: 200))
        }
        do {
            _ = try await StreamPreflight(http: http).prepare(proxy, headers: [:])
            XCTFail("应报不是播放列表")
        } catch let error as StreamPreflightError {
            guard case .notPlaylist = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }
}
