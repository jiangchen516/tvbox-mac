// CatVodTests.swift — CatVod URL 构造 + 响应解析（用 mock HTTP，不联网）
import XCTest
@testable import TVBoxMacCore

/// 测试用 mock：按 URL 模式返回预置响应；未命中时返回 catvod-browse fixture
final class MockHTTP: HTTPFetching {
    struct Case {
        let match: (String) -> Bool
        let status: Int
        let body: String
    }
    var cases: [Case] = []
    var requests: [String] = []

    var defaultBody: String = MockHTTP.browseFixture

    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        let s = url.absoluteString
        requests.append(s)
        if let c = cases.first(where: { $0.match(s) }) {
            return (Data(c.body.utf8), HTTPResponse(url: url, statusCode: c.status))
        }
        return (Data(defaultBody.utf8), HTTPResponse(url: url, statusCode: 200))
    }

    static var browseFixture: String {
        let url = Bundle.module.url(forResource: "catvod-browse", withExtension: "json",
                                    subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "catvod-browse", withExtension: "json")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

final class CatVodTests: XCTestCase {

    func makeClient(_ mock: MockHTTP) -> CatVodClient {
        CatVodClient(http: mock, adFilter: AdFilter())
    }

    func testBuildApiUrlNoSlashNoQuery() async throws {
        // api 无 ? 无尾斜杠 → api + "?ac=detail&..."
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/api.php/provide/vod", type: 1,
                        categories: ["电影"])
        let page = try await client.browse(site: site, category: "电影", page: 2)
        XCTAssertFalse(mock.requests.isEmpty)
        let req = mock.requests[0]
        XCTAssertTrue(req.hasPrefix("https://a.com/api.php/provide/vod?ac=detail&"), req)
        XCTAssertTrue(req.contains("t=%E7%94%B5%E5%BD%B1"), req)  // 中文分类 percent-encode
        XCTAssertTrue(req.contains("pg=2"), req)
        XCTAssertEqual(page.pagecount, 5)
    }

    func testBuildApiUrlWithQuery() async throws {
        // api 已含 ? → 用 & 拼接
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/api.php/provide/vod?ac=detail", type: 1)
        _ = try await client.search(site: site, keyword: "测试", page: 1)
        let req = mock.requests[0]
        XCTAssertTrue(req.contains("wd="), req)
        XCTAssertFalse(req.contains("??"), req)
    }

    func testBuildApiUrlTrailingSlash() async throws {
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/api.php/provide/vod/", type: 1)
        _ = try await client.browse(site: site, category: nil, page: 1)
        let req = mock.requests[0]
        XCTAssertFalse(req.contains("//?"), req)   // 不产生 斜杠+?  的怪异拼接
        XCTAssertTrue(req.contains("?ac=detail"), req)
    }

    func testSearchEncoding() async throws {
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        _ = try await client.search(site: site, keyword: "战狼2", page: 3)
        let req = mock.requests[0]
        XCTAssertTrue(req.contains("wd="), req)
        XCTAssertTrue(req.contains("pg=3"), req)
    }

    func testDetailTakesFirstVod() async throws {
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        let vod = try await client.detail(site: site, vodId: 101)
        // detail 请求必须带 ids= 参数
        XCTAssertTrue(mock.requests[0].contains("ids=101"), mock.requests[0])
        XCTAssertEqual(vod.vod_id, 101)
        XCTAssertEqual(vod.vod_name, "测试电影A")
    }

    func testCategoriesFromConfig() async throws {
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1,
                        categories: ["电影", "动漫"])
        let cats = try await client.categories(site: site)
        XCTAssertEqual(cats, ["电影", "动漫"])
    }

    func testResolvePlayUrlDecodesBase64UrlParam() async throws {
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        // url= 参数是 base64 编码的直链
        let real = "https://cdn.example.com/real.m3u8"
        let b64 = Data(real.utf8).base64EncodedString()
        let ep = Episode(title: "第1集", url: "https://p.example.com/play?uid=1&url=\(b64)",
                         group: "g", index: 0)
        let vod = Vod(vod_id: 1, vod_name: "t")
        let resolved = try await client.resolvePlayUrl(site: site, vod: vod, episode: ep)
        XCTAssertEqual(resolved, real)
    }

    func testResolvePlayUrlNoParsesReturnsOriginal() async throws {
        let mock = MockHTTP()
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        let ep = Episode(title: "第1集", url: "https://cdn.example.com/x.m3u8", group: "g", index: 0)
        let vod = Vod(vod_id: 1, vod_name: "t")
        let resolved = try await client.resolvePlayUrl(site: site, vod: vod, episode: ep)
        XCTAssertEqual(resolved, "https://cdn.example.com/x.m3u8")
    }

    // 真实源实测：code=1 + list 是成功（「数据列表」）；code 只在缺 list 时间接体现为错误
    func testMissingListWithCodeOneThrows() async throws {
        let mock = MockHTTP()
        mock.cases.append(.init(match: { _ in true }, status: 200,
                                body: #"{"code": 1, "msg": "token 过期"}"#))
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        do {
            _ = try await client.browse(site: site, category: nil, page: 1)
            XCTFail("应当抛错")
        } catch let e as HTTPClientError {
            if case .jsonParse = e {} else { XCTFail("错误类型应为 jsonParse（响应缺少 list），实际: \(e)") }
        }
    }

    // 真实源实测：部分源 page/pagecount/limit/total 返回字符串，code=1 为成功
    func testStringEnvelopeFieldsDecode() async throws {
        let mock = MockHTTP()
        mock.cases.append(.init(match: { _ in true }, status: 200,
                                body: #"{"code":1,"msg":"数据列表","page":"1","pagecount":"7181","limit":"20","total":"143602","list":[{"vod_id":154956,"vod_name":"寄生之心"}]}"#))
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        let page = try await client.browse(site: site, category: nil, page: 1)
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.pagecount, 7181)
        XCTAssertEqual(page.total, 143602)
        XCTAssertEqual(page.list.first?.vod_name, "寄生之心")
    }

    func testStripLocalProxy() {
        // TVBox 本机代理约定：还原真实地址
        let proxied = URL(string: "http://127.0.0.1:10079/p/0/proxy/https://ikunzyapi.com/api.php/provide/vod/?ac=detail&pg=1")!
        XCTAssertEqual(HTTPDefaults.stripLocalProxy(proxied).absoluteString,
                       "https://ikunzyapi.com/api.php/provide/vod/?ac=detail&pg=1")
        // 非 localhost 不动
        let direct = URL(string: "https://suoniapi.com/api.php/provide/vod/from/snm3u8/?ac=detail&pg=1")!
        XCTAssertEqual(HTTPDefaults.stripLocalProxy(direct), direct)
        // localhost 但无 proxy 路径，不动
        let other = URL(string: "http://localhost:9978/file/x.txt")!
        XCTAssertEqual(HTTPDefaults.stripLocalProxy(other), other)
    }

    // 真实源实测：t=分类名返回 0 条，t=type_id 正常；分类需经 ac=list 的 class 映射
    func testCategoryNameMappedToTypeId() async throws {
        let mock = MockHTTP()
        mock.cases.append(.init(match: { $0.contains("ac=list") }, status: 200,
                                body: #"{"code":1,"class":[{"type_id":1,"type_name":"电影"},{"type_id":2,"type_name":"电视剧"}]}"#))
        mock.cases.append(.init(match: { $0.contains("ac=detail") }, status: 200,
                                body: #"{"code":1,"page":"1","pagecount":"3","limit":"20","total":"2","list":[{"vod_id":9,"vod_name":"测试片"}]}"#))
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        let names = try await client.categories(site: site)
        XCTAssertEqual(names.first, "电影")
        let page = try await client.browse(site: site, category: "电影", page: 1)
        XCTAssertEqual(page.list.first?.vod_name, "测试片")
        // 请求应传 t=1（type_id）而非 t=电影
        let detailReq = mock.requests.first { $0.contains("ac=detail") }
        XCTAssertTrue(detailReq?.contains("t=1") ?? false, "应传 type_id，实际: \(detailReq ?? "?")")
        XCTAssertFalse(detailReq?.contains("t=%E7%94%B5%E5%BD%B1") ?? true, "不应传分类名")
    }

    func testMissingListThrows() async throws {
        let mock = MockHTTP()
        mock.cases.append(.init(match: { _ in true }, status: 200, body: #"{"code":0}"#))
        let client = makeClient(mock)
        let site = Site(key: "s", name: "s", api: "https://a.com/vod", type: 1)
        do {
            _ = try await client.browse(site: site, category: nil, page: 1)
            XCTFail("应当抛错")
        } catch is HTTPClientError {
            // 预期
        }
    }
}

// MARK: - mock 数据注入：让 browse/detail 返回 catvod-browse fixture
extension CatVodTests {
    func loadBrowseFixture() -> String {
        let url = Bundle.module.url(forResource: "catvod-browse", withExtension: "json",
                                    subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "catvod-browse", withExtension: "json")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
