// AdFilterTests.swift — 去广告
import XCTest
@testable import TVBoxMacCore

final class AdFilterTests: XCTestCase {

    private let filter = AdFilter()

    private var fixtureM3u8: String {
        let url = Bundle.module.url(forResource: "m3u8-with-ads", withExtension: "txt",
                                    subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "m3u8-with-ads", withExtension: "txt")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testM3u8RemovesAdLines() {
        let out = filter.apply(to: fixtureM3u8)
        // 广告频道行 + #EXTVLCOPT 行应被删
        XCTAssertFalse(out.contains("广告频道"), out)
        XCTAssertFalse(out.contains("#EXTVLCOPT"), out)
        // 正常频道保留
        XCTAssertTrue(out.contains("测试频道"), out)
        XCTAssertTrue(out.contains("test.m3u8"), out)
        XCTAssertTrue(out.hasPrefix("#EXTM3U"), out)
    }

    func testM3u8CleansAdParamsOnUrl() {
        let out = filter.apply(to: fixtureM3u8)
        // test2 的 url 里 adurl 参数应被清理，token 保留
        let line = String(out.split(separator: "\n").first { $0.contains("test2.m3u8") } ?? "")
        XCTAssertFalse(line.contains("adurl"), line)
        XCTAssertTrue(line.contains("token=abc"), line)
    }

    func testUrlAdTailRemoved() {
        let out = filter.apply(to: "https://cdn.example.com/a.m3u8#广告尾缀")
        XCTAssertEqual(out, "https://cdn.example.com/a.m3u8")
    }

    func testUrlNormalUnchanged() {
        let out = filter.apply(to: "https://cdn.example.com/a.m3u8?token=abc")
        XCTAssertEqual(out, "https://cdn.example.com/a.m3u8?token=abc")
    }

    func testPlainStringPassthrough() {
        let out = filter.apply(to: "hello world")
        XCTAssertEqual(out, "hello world")
    }
}
