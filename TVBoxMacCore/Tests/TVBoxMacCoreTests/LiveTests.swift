// LiveTests.swift — 直播播放列表解析 / 源解析 / 加载缓存（全部离线）
import XCTest
import CoreFoundation
@testable import TVBoxMacCore

private struct MockLiveHTTP: HTTPFetching {
    let data: Data
    let status: Int

    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        (data, HTTPResponse(url: url, statusCode: status))
    }
}

private struct FailingLiveHTTP: HTTPFetching {
    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private actor CountingLiveHTTP: HTTPFetching {
    let data: Data
    private var calls = 0

    init(data: Data) { self.data = data }

    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        calls += 1
        return (data, HTTPResponse(url: url, statusCode: 200))
    }

    func callCount() -> Int { calls }
}

final class LiveTests: XCTestCase {

    // MARK: - txt

    func testTXTParseGroupsAndMultiURL() {
        let text = """
        央视,#genre#
        CCTV-1 综合,http://example.com/1.m3u8#http://example.com/1b.m3u8
        CCTV-2 财经,http://example.com/2.m3u8

        卫视,#genre#
        湖南卫视,http://example.com/hn.m3u8
        """
        let genres = LiveParser.parse(text)
        XCTAssertEqual(genres.map(\.name), ["央视", "卫视"])
        XCTAssertEqual(genres[0].channels.count, 2)
        XCTAssertEqual(genres[0].channels[0].name, "CCTV-1 综合")
        XCTAssertEqual(genres[0].channels[0].urls,
                       ["http://example.com/1.m3u8", "http://example.com/1b.m3u8"])
        XCTAssertEqual(genres[1].channels.first?.name, "湖南卫视")
    }

    func testTXTChannelsBeforeFirstGenreAreUnclassified() {
        let genres = LiveParser.parse("CCTV-1,http://example.com/1.m3u8")
        XCTAssertEqual(genres.count, 1)
        XCTAssertEqual(genres[0].name, "未分类")
        XCTAssertEqual(genres[0].channels.first?.urls, ["http://example.com/1.m3u8"])
    }

    func testTXTParseMergesDuplicateChannelsAndDropsDuplicateURLs() {
        let text = """
        央视,#genre#
        CCTV-1,http://example.com/a.m3u8
        CCTV-1,http://example.com/b.m3u8#http://example.com/a.m3u8
        """
        let genres = LiveParser.parse(text)
        XCTAssertEqual(genres[0].channels.count, 1)
        XCTAssertEqual(genres[0].channels[0].urls,
                       ["http://example.com/a.m3u8", "http://example.com/b.m3u8"])
    }

    func testTXTParseToleratesCRLFBlankLinesAndComments() {
        let text = "# 这是注释\r\n\r\n央视,#genre#\r\nCCTV-1,http://example.com/a.m3u8   \r\n"
        let genres = LiveParser.parse(text)
        XCTAssertEqual(genres.count, 1)
        XCTAssertEqual(genres[0].channels.first?.urls, ["http://example.com/a.m3u8"])
    }

    func testTXTParseSkipsLinesWithoutURL() {
        let text = """
        央视,#genre#
        只有名字,
        没逗号的一行
        CCTV-1,http://example.com/a.m3u8
        """
        let genres = LiveParser.parse(text)
        XCTAssertEqual(genres[0].channels.map(\.name), ["CCTV-1"])
    }

    // MARK: - m3u

    func testM3UParseAttributesAndGroup() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV1" tvg-logo="http://example.com/logo.png" group-title="央视",CCTV-1 综合
        http://example.com/1.m3u8
        #EXTINF:-1 group-title="卫视",湖南卫视
        http://example.com/hn.m3u8
        """
        let genres = LiveParser.parse(text)
        XCTAssertEqual(genres.map(\.name), ["央视", "卫视"])
        let cctv = genres[0].channels[0]
        XCTAssertEqual(cctv.name, "CCTV-1 综合")
        XCTAssertEqual(cctv.logo, "http://example.com/logo.png")
        XCTAssertEqual(cctv.tvgID, "cctv1")
        XCTAssertEqual(cctv.urls, ["http://example.com/1.m3u8"])
    }

    func testM3UNameMayContainComma() {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="电影",CCTV-6, 电影频道
        http://example.com/movie.m3u8
        """
        let genres = LiveParser.parse(text)
        XCTAssertEqual(genres[0].channels.first?.name, "CCTV-6, 电影频道")
    }

    func testM3UWithoutQuotedAttributes() {
        let genres = LiveParser.parse("#EXTM3U\n#EXTINF:-1,CCTV-1\nhttp://example.com/1.m3u8")
        XCTAssertEqual(genres[0].channels.first?.name, "CCTV-1")
        XCTAssertEqual(genres[0].channels.first?.group, "未分类")
    }

    func testM3UIgnoresCommentsAndOrphanURL() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        http://example.com/orphan.m3u8
        #EXTINF:-1,A
        #EXTVLCOPT:http-user-agent=test
        http://example.com/a.m3u8
        """
        let genres = LiveParser.parse(text)
        XCTAssertEqual(genres.count, 1)
        XCTAssertEqual(genres[0].channels.map(\.name), ["A"])
    }

    func testParseAutoDetectsFormat() {
        let m3u = LiveParser.parse("#EXTM3U\n#EXTINF:-1,A\nhttp://example.com/a.m3u8")
        XCTAssertEqual(m3u[0].channels.first?.name, "A")
        let txt = LiveParser.parse("央视,#genre#\nB,http://example.com/b.m3u8")
        XCTAssertEqual(txt[0].name, "央视")
    }

    func testParseEmptyAndGarbageReturnsEmpty() {
        XCTAssertTrue(LiveParser.parse("").isEmpty)
        XCTAssertTrue(LiveParser.parse("   \n\n").isEmpty)
        XCTAssertTrue(LiveParser.parse("not a playlist at all").isEmpty)
    }

    // MARK: - LiveSource

    func testLiveSourceFromObject() {
        let raw = JSONValue.object([
            "name": .string("我的直播"),
            "url": .string("https://example.com/live.txt"),
            "group": .string("默认"),
            "ua": .string("CustomUA/1.0"),
            "header": .string("Referer:https://example.com"),
            "epg": .string("https://example.com/epg.xml"),
            "playerType": .number(1)
        ])
        let source = LiveSource.make(from: raw, configURL: nil, index: 0)
        XCTAssertEqual(source.name, "我的直播")
        XCTAssertEqual(source.group, "默认")
        XCTAssertEqual(source.playerType, "1")
        XCTAssertTrue(source.isHTTPPlaylist)
        XCTAssertNil(source.unsupportedReason)
        let headers = source.requestHeaders
        XCTAssertEqual(headers["User-Agent"], "CustomUA/1.0")
        XCTAssertEqual(headers["Referer"], "https://example.com")
    }

    func testLiveSourceFromBareStringUsesFileStemAsName() {
        let source = LiveSource.make(from: .string("https://example.com/lists/china.txt"),
                                     configURL: nil, index: 0)
        XCTAssertEqual(source.name, "china")
        XCTAssertEqual(source.url, "https://example.com/lists/china.txt")
    }

    func testLiveSourceResolvesRelativeURLAgainstConfig() {
        let source = LiveSource.make(from: .object(["url": .string("./live/list.txt")]),
                                     configURL: "https://example.com/config/app.json", index: 0)
        XCTAssertEqual(source.url, "https://example.com/config/live/list.txt")
    }

    func testLiveSourceInlineChannels() {
        let raw = JSONValue.object([
            "group": .string("自定义"),
            "channels": .array([
                .object([
                    "name": .string("频道A"),
                    "urls": .array([.string("http://example.com/a.m3u8"),
                                    .string("http://example.com/b.m3u8")])
                ]),
                .object([
                    "name": .string("频道B"),
                    "url": .string("http://example.com/c.m3u8")
                ]),
                .object(["name": .string("无地址")])
            ])
        ])
        let source = LiveSource.make(from: raw, configURL: nil, index: 0)
        XCTAssertTrue(source.hasInlineChannels)
        XCTAssertFalse(source.isHTTPPlaylist)
        XCTAssertNil(source.unsupportedReason)
        // 没有 urls 的频道被跳过
        XCTAssertEqual(source.inlineChannels.map(\.name), ["频道A", "频道B"])
        XCTAssertEqual(source.inlineChannels[0].group, "自定义")
        XCTAssertEqual(source.inlineChannels[0].urls,
                       ["http://example.com/a.m3u8", "http://example.com/b.m3u8"])
        XCTAssertEqual(source.inlineChannels[1].urls, ["http://example.com/c.m3u8"])
    }

    func testLiveSourceWithoutURLIsUnsupportedButKept() {
        let source = LiveSource.make(from: .object(["name": .string("Spider 直播"),
                                                    "api": .string("csp_live")]),
                                     configURL: nil, index: 2)
        XCTAssertEqual(source.name, "Spider 直播")
        XCTAssertFalse(source.isHTTPPlaylist)
        XCTAssertNotNil(source.unsupportedReason)
    }

    // MARK: - 文本解码

    func testDecodesGB18030Playlist() throws {
        let text = "央视,#genre#\nCCTV-1 综合,http://example.com/a.m3u8\n"
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let encoding = String.Encoding(rawValue: cf)
        let data = try XCTUnwrap(text.data(using: encoding))
        let decoded = try XCTUnwrap(LiveTextDecoder.decode(data))
        XCTAssertTrue(decoded.contains("CCTV-1 综合"))
        XCTAssertEqual(LiveParser.parse(decoded).first?.channels.first?.name, "CCTV-1 综合")
    }

    func testDecodesBase64WrappedPlaylist() throws {
        let inner = "#EXTM3U\n#EXTINF:-1,频道A\nhttp://example.com/a.m3u8\n"
        let wrapped = Data(inner.utf8).base64EncodedData()
        let text = try XCTUnwrap(LiveTextDecoder.playlistText(from: wrapped))
        XCTAssertTrue(text.contains("#EXTM3U"))
        XCTAssertEqual(LiveParser.parse(text).first?.channels.first?.name, "频道A")
    }

    // MARK: - LiveClient

    private func makeSource(_ url: String = "https://example.com/live.txt") -> LiveSource {
        LiveSource(name: "测试源", url: url)
    }

    func testClientLoadsAndCaches() async throws {
        let http = CountingLiveHTTP(data: Data("央视,#genre#\nCCTV-1,http://example.com/a.m3u8".utf8))
        let client = LiveClient(http: http)
        let first = try await client.load(makeSource())
        XCTAssertEqual(first.first?.channels.count, 1)
        let second = try await client.load(makeSource())
        XCTAssertEqual(second.first?.channels.count, 1)
        let calls = await http.callCount()
        XCTAssertEqual(calls, 1, "TTL 内应命中缓存，不再请求网络")
        let cached = await client.isCached(makeSource())
        XCTAssertTrue(cached)
    }

    func testClientForceReloadBypassesCache() async throws {
        let http = CountingLiveHTTP(data: Data("A,http://example.com/a.m3u8".utf8))
        let client = LiveClient(http: http)
        _ = try await client.load(makeSource())
        _ = try await client.load(makeSource(), forceReload: true)
        let calls = await http.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testClientReturnsInlineChannelsWithoutNetwork() async throws {
        let client = LiveClient(http: FailingLiveHTTP())
        let source = LiveSource(name: "内联", url: "", inlineChannels: [
            LiveChannel(name: "A", group: "组1", urls: ["http://example.com/a.m3u8"]),
            LiveChannel(name: "B", group: "组1", urls: ["http://example.com/b.m3u8"]),
            LiveChannel(name: "C", group: "组2", urls: ["http://example.com/c.m3u8"])
        ])
        let genres = try await client.load(source)
        XCTAssertEqual(genres.map(\.name), ["组1", "组2"])
        XCTAssertEqual(genres[0].channels.count, 2)
        XCTAssertEqual(genres[1].channels.first?.name, "C")
    }

    func testClientThrowsNoChannelsForNonPlaylist() async {
        let http = MockLiveHTTP(data: Data("not a playlist".utf8), status: 200)
        let client = LiveClient(http: http)
        do {
            _ = try await client.load(makeSource())
            XCTFail("应报没有频道")
        } catch let error as LiveError {
            guard case .noChannels = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testClientThrowsUnsupportedForNonHTTP() async {
        let client = LiveClient(http: MockLiveHTTP(data: Data(), status: 200))
        do {
            _ = try await client.load(makeSource("proxy://live/channels"))
            XCTFail("应报不支持")
        } catch let error as LiveError {
            guard case .unsupportedSource = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }
}
