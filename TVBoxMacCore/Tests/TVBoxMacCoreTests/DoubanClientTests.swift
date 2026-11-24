// DoubanClientTests.swift — 豆瓣首页集合解析（字段缺失/漂移回归）
import XCTest
@testable import TVBoxMacCore

private struct MockDoubanHTTP: HTTPFetching {
    let data: Data
    let status: Int

    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        (data, HTTPResponse(url: url, statusCode: status))
    }
}

final class DoubanClientTests: XCTestCase {
    private let sample = """
    {"start":0,"count":2,"total":2,"subject_collection_items":[
      {"id":"35235320","title":"两京十五日","type":"tv","year":"2026",
       "card_subtitle":"2026 / 中国大陆 / 剧情 古装",
       "episodes_info":"更新至8集",
       "pic":{"large":"https://img.example/large.jpg","normal":"https://img.example/normal.jpg"},
       "rating":{"value":8.4}},
      {"id":"36689621","title":"今天是太阳雨",
       "pic":{"normal":"https://img.example/n2.jpg"}}
    ]}
    """.data(using: .utf8)!

    func testDecodesSubjectsAndPosterPreference() async throws {
        let client = DoubanClient(http: MockDoubanHTTP(data: sample, status: 200))
        let items = try await client.items(collection: "tv_hot", count: 2)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "35235320")
        XCTAssertEqual(items[0].title, "两京十五日")
        XCTAssertEqual(items[0].posterURL, "https://img.example/large.jpg")
        XCTAssertEqual(items[0].scoreText, "8.4")
        XCTAssertEqual(items[0].episodesInfo, "更新至8集")
        // 第二条只有 normal 图、无 rating：不能崩，回退 normal
        XCTAssertEqual(items[1].posterURL, "https://img.example/n2.jpg")
        XCTAssertNil(items[1].scoreText)
        XCTAssertEqual(items[1].year, nil)
    }

    // “正在热映”集合用的是 cover.url，而不是 pic.large/normal
    func testDecodesCoverURLForNowShowing() async throws {
        let json = """
        {"subject_collection_items":[{"id":"1","title":"饥饿游戏","type":"movie",
          "cover":{"url":"https://img.example/cover.jpg","width":4051,"height":6510}}]}
        """.data(using: .utf8)!
        let client = DoubanClient(http: MockDoubanHTTP(data: json, status: 200))
        let items = try await client.items(collection: "movie_showing")
        XCTAssertEqual(items.first?.posterURL, "https://img.example/cover.jpg")
    }

    func testMalformedJSONThrowsParseError() async {
        let client = DoubanClient(http: MockDoubanHTTP(data: Data("<html>".utf8), status: 200))
        do {
            _ = try await client.items(collection: "tv_hot")
            XCTFail("HTML 响应应报解析失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("豆瓣集合"))
        }
    }
}
