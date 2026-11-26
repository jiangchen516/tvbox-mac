// LiveCacheTests.swift — 直播列表磁盘缓存兜底（离线）
import XCTest
@testable import TVBoxMacCore

private struct CacheOKHTTP: HTTPFetching {
    let data: Data
    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        (data, HTTPResponse(url: url, statusCode: 200))
    }
}

private struct CacheFailHTTP: HTTPFetching {
    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

final class LiveCacheTests: XCTestCase {
    func testFallsBackToDiskCacheWhenNetworkFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LiveSource(name: "测试源", url: "https://example.com/live.txt")

        let online = LiveClient(http: CacheOKHTTP(data: Data("央视,#genre#\nCCTV-1,http://example.com/a.m3u8".utf8)),
                                diskCacheDirectory: dir)
        let first = try await online.load(source)
        XCTAssertEqual(first.first?.channels.count, 1)

        let offline = LiveClient(http: CacheFailHTTP(), diskCacheDirectory: dir)
        let cached = try await offline.load(source)
        XCTAssertEqual(cached.first?.channels.first?.name, "CCTV-1")
    }

    func testWithoutCacheNetworkErrorStillThrows() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = LiveClient(http: CacheFailHTTP(), diskCacheDirectory: dir)
        do {
            _ = try await client.load(LiveSource(name: "x", url: "https://example.com/none.txt"))
            XCTFail("没有缓存时应抛错")
        } catch let error as LiveError {
            guard case .requestFailed = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }
}
