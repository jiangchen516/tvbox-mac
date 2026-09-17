// ModelsTests.swift — 类型契约 + Vod 选集解析
import XCTest
@testable import TVBoxMacCore

final class ModelsTests: XCTestCase {

    // MARK: - Vod 选集解析

    func testPlayGroups() {
        let vod = Vod(vod_id: 1, vod_name: "t", vod_play_from: "线路1#线路2#线路3")
        XCTAssertEqual(vod.playGroups, ["线路1", "线路2", "线路3"])
    }

    // 真实源实测（虎牙资源站）：play_from 用 $$$ 分组、组内集用 title$url（单美元符）
    func testPlayGroupsAndEpisodesDollarConvention() {
        let vod = Vod(vod_id: 1, vod_name: "t",
                      vod_play_from: "hyyun$$$hym3u8",
                      vod_play_url: "第1集$https://hd/play/a#第2集$https://hd/play/b$$$第1集$https://hd/play/a/index.m3u8#第2集$https://hd/play/b/index.m3u8")
        XCTAssertEqual(vod.playGroups, ["hyyun", "hym3u8"], "play_from 应按 $$$ 拆组")
        let direct = vod.episodes(group: "hym3u8")
        XCTAssertEqual(direct.map(\.url), ["https://hd/play/a/index.m3u8", "https://hd/play/b/index.m3u8"])
        XCTAssertEqual(direct[0].title, "第1集")
        XCTAssertTrue(direct[0].isDirectMedia)
        let web = vod.episodes(group: "hyyun")
        XCTAssertEqual(web[0].url, "https://hd/play/a")
        XCTAssertFalse(web[0].isDirectMedia, "网页播放页不是直连媒体")
    }

    func testEpisodesSingleGroup() {
        let vod = Vod(vod_id: 1, vod_name: "t",
                      vod_play_from: "直连",
                      vod_play_url: "第1集|https://cdn/a1.mp4#第2集|https://cdn/a2.mp4")
        let eps = vod.episodes(group: "直连")
        XCTAssertEqual(eps.count, 2)
        XCTAssertEqual(eps[0].title, "第1集")
        XCTAssertEqual(eps[0].url, "https://cdn/a1.mp4")
        XCTAssertEqual(eps[1].group, "直连")
    }

    func testEpisodesMultiGroup() {
        let vod = Vod(vod_id: 1, vod_name: "t",
                      vod_play_from: "线路A#线路B",
                      vod_play_url: "1|https://a/1.mp4#2|https://a/2.mp4$$$1|https://b/1.mp4#2|https://b/2.mp4")
        let a = vod.episodes(group: "线路A")
        let b = vod.episodes(group: "线路B")
        XCTAssertEqual(a.map(\.url), ["https://a/1.mp4", "https://a/2.mp4"])
        XCTAssertEqual(b.map(\.url), ["https://b/1.mp4", "https://b/2.mp4"])
        XCTAssertEqual(a[0].group, "线路A")
        XCTAssertEqual(b[0].group, "线路B")
    }

    func testEpisodesEmptyTitleFallsBack() {
        let vod = Vod(vod_id: 1, vod_name: "t",
                      vod_play_from: "直连",
                      vod_play_url: "|https://cdn/a1.mp4#|https://cdn/a2.mp4")
        let eps = vod.episodes(group: "直连")
        XCTAssertEqual(eps.count, 2)
        XCTAssertEqual(eps[0].title, "第1集")
        XCTAssertEqual(eps[1].title, "第2集")
    }

    func testEpisodesSkipsEmptyUrl() {
        let vod = Vod(vod_id: 1, vod_name: "t",
                      vod_play_from: "直连",
                      vod_play_url: "第1集||第2集|https://cdn/a2.mp4")
        let eps = vod.episodes(group: "直连")
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps[0].url, "https://cdn/a2.mp4")
    }

    func testEpisodesEmptyPlayUrl() {
        let vod = Vod(vod_id: 1, vod_name: "t")
        XCTAssertTrue(vod.episodes(group: "x").isEmpty)
        XCTAssertTrue(vod.playGroups.isEmpty)
    }

    // MARK: - HeaderParser

    func testHeaderParserSemicolon() {
        let h = HeaderParser.parse("User-Agent: okhttp/3.10.0;Referer: https://x.com/a b")
        XCTAssertEqual(h["User-Agent"], "okhttp/3.10.0")
        XCTAssertEqual(h["Referer"], "https://x.com/a b")
    }

    func testHeaderParserJSON() {
        let h = HeaderParser.parse("{\"User-Agent\": \"tv\", \"X-Token\": \"abc\"}")
        XCTAssertEqual(h["User-Agent"], "tv")
        XCTAssertEqual(h["X-Token"], "abc")
    }

    func testHeaderParserEmpty() {
        XCTAssertTrue(HeaderParser.parse(nil).isEmpty)
        XCTAssertTrue(HeaderParser.parse("  ").isEmpty)
    }

    // MARK: - 宽容解码

    func testTVBoxConfigLenientDecode() throws {
        let json = """
        {"sites": [{"name": "甲", "api": "https://a.com/api.php/provide/vod/", "type": 1}],
         "parses": [{"name": "p", "url": "https://p.com/x", "type": 1}]}
        """
        let cfg = try JSONDecoder().decode(TVBoxConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.sites.count, 1)
        XCTAssertEqual(cfg.sites[0].name, "甲")
        XCTAssertEqual(cfg.sites[0].type, 1)
        XCTAssertEqual(cfg.sites[0].searchable, 1)   // 缺省默认 1
        XCTAssertEqual(cfg.parses.count, 1)
        XCTAssertEqual(cfg.timeout, 15)               // 缺省默认 15
    }

    func testTVBoxConfigMissingSites() throws {
        let json = #"{"parses": []}"#
        let cfg = try JSONDecoder().decode(TVBoxConfig.self, from: Data(json.utf8))
        XCTAssertTrue(cfg.sites.isEmpty)
    }

    func testSiteKeyAndId() {
        let s1 = Site(key: "fty", name: "饭太硬", api: "https://a.com/")
        XCTAssertEqual(s1.id, "fty")
        let s2 = Site(name: "无key", api: "https://b.com/")
        XCTAssertEqual(s2.id, "无key|https://b.com/")
    }
}
