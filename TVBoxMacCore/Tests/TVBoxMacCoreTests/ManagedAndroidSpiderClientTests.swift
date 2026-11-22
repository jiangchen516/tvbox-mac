import XCTest
@testable import TVBoxMacCore

private actor FakeDexTransport: AndroidDexBridgeTransport {
    private let responses: [AndroidDexBridgeResponse]
    private var responseIndex = 0
    private(set) var lastSentRequest: AndroidDexBridgeRequest?

    init(response: AndroidDexBridgeResponse) {
        self.responses = [response]
    }

    init(responses: [AndroidDexBridgeResponse]) {
        self.responses = responses
    }

    func send(_ request: AndroidDexBridgeRequest) async throws -> AndroidDexBridgeResponse {
        lastSentRequest = request
        let response = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        return response
    }

    func lastRequest() -> AndroidDexBridgeRequest? {
        lastSentRequest
    }
}

private actor CancelledDexTransport: AndroidDexBridgeTransport {
    func send(_ request: AndroidDexBridgeRequest) async throws -> AndroidDexBridgeResponse {
        throw URLError(.cancelled)
    }
}

final class ManagedAndroidSpiderClientTests: XCTestCase {
    func testTransportCancellationIsNotWrappedAsBridgeFailure() async throws {
        let client = ManagedAndroidSpiderClient(transport: CancelledDexTransport())
        let site = Site(name: "糯米", api: "csp_NmyswvGuard", type: 3)

        do {
            _ = try await client.categories(site: site)
            XCTFail("应保留任务取消")
        } catch is CancellationError {
            // Expected: navigation cancellation must not be reported as a source error.
        } catch {
            XCTFail("取消不应包装成普通 Bridge 错误: \(error)")
        }
    }

    func testCategoriesDecodesBridgeResponse() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true,
            data: .object(["categories": .array([.string("电影"), .string("电视剧")])])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(name: "测试", api: "csp_Test", type: 3)

        let categories = try await client.categories(site: site)

        XCTAssertEqual(categories, ["电影", "电视剧"])
    }

    func testSpiderPageDecodesStringPageNumberAndVodStringID() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true,
            data: .object([
                "page": .string("1"),
                "pagecount": .number(2_147_483_647),
                "limit": .number(29),
                "total": .number(2_147_483_647),
                "list": .array([.object([
                    "vod_id": .string("/vod-detail-id-112330.html"),
                    "vod_name": .string("远方的魔法树"),
                    "vod_pic": .string("https://img.example/poster.jpg"),
                    "vod_remarks": .string("HD中字")
                ])])
            ])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(key: "糯米", name: "糯米", api: "csp_NmyswvGuard", type: 3)

        let result = try await client.search(site: site, keyword: "测试", page: 1)

        XCTAssertEqual(result.page, 1)
        XCTAssertEqual(result.pagecount, 2_147_483_647)
        XCTAssertEqual(result.limit, 29)
        XCTAssertEqual(result.list.first?.displayId, "/vod-detail-id-112330.html")
        XCTAssertEqual(result.list.first?.vod_name, "远方的魔法树")
    }

    func testBrowseDecodesGuardStringPageNumber() async throws {
        let transport = FakeDexTransport(responses: [
            AndroidDexBridgeResponse(
                id: "1", ok: true,
                data: .object(["class": .array([.object([
                    "type_name": .string("电影"),
                    "type_id": .string("1")
                ])])])
            ),
            AndroidDexBridgeResponse(
                id: "2", ok: true,
                data: .object([
                    "page": .string("1"),
                    "pagecount": .number(2_147_483_647),
                    "limit": .number(29),
                    "total": .number(2_147_483_647),
                    "list": .array([.object([
                        "vod_id": .string("/vod-detail-id-112330.html"),
                        "vod_name": .string("远方的魔法树"),
                        "vod_pic": .string("https://img.example/poster.jpg"),
                        "vod_remarks": .string("HD中字")
                    ])])
                ])
            )
        ])
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(key: "糯米", name: "糯米", api: "csp_NmyswvGuard", type: 3)

        let result = try await client.browse(site: site, category: "电影", page: 1)

        XCTAssertEqual(result.page, 1)
        XCTAssertEqual(result.pagecount, 2_147_483_647)
        XCTAssertEqual(result.limit, 29)
        XCTAssertEqual(result.list.first?.displayId, "/vod-detail-id-112330.html")
        XCTAssertEqual(result.list.first?.vod_name, "远方的魔法树")
    }

    func testPlayResponseRequiresUrl() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true, data: .object(["value": .string("missing")])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(name: "测试", api: "csp_Test", type: 3)
        let vod = Vod(vod_id: 1, vod_name: "片")
        let episode = Episode(title: "第1集", url: "https://example.invalid/ep", group: "直连", index: 0)

        do {
            _ = try await client.resolvePlayUrl(site: site, vod: vod, episode: episode)
            XCTFail("应当拒绝缺少 url 的响应")
        } catch let error as ManagedAndroidSpiderError {
            guard case .invalidResponse = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }
    }

    func testBridgeErrorIsSurfaced() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: false, error: "class not found"
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(name: "测试", api: "csp_Test", type: 3)

        do {
            _ = try await client.search(site: site, keyword: "测试", page: 1)
            XCTFail("应当抛出 Bridge 错误")
        } catch let error as ManagedAndroidSpiderError {
            guard case .bridge(let message) = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssertEqual(message, "class not found")
        }
    }

    func testConfigLevelSpiderURLFillsMissingSiteJar() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true,
            data: .object(["categories": .array([])])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        await client.setGlobalSpiderURL("https://example.com/tvbox.jar")
        let site = Site(name: "饭太硬", api: "csp_Test", type: 3)

        _ = try await client.categories(site: site)

        let request = await transport.lastRequest()
        XCTAssertEqual(request?.site.jar, "https://example.com/tvbox.jar")
    }

    // 实测：dex spider 的 detail 返回 FongMi/CatVod 信封 {"list":[vod]}，
    // 直接按 Vod 解码得到全空字段 → 详情页「未知/空白/无链接」
    func testDetailDecodesListEnvelope() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true,
            data: .object(["list": .array([.object([
                "vod_id": .number(93431),
                "vod_name": .string("剧场版 紧急审讯室"),
                "vod_play_from": .string("线路1$$$线路2"),
                "vod_play_url": .string("第1集|https://a/1.m3u8$$$第1集|https://b/1.m3u8")
            ])])])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(name: "测试", api: "csp_Test", type: 3)

        let vod = try await client.detail(site: site, vodId: "93431")

        XCTAssertEqual(vod.vod_name, "剧场版 紧急审讯室")
        XCTAssertEqual(vod.vod_id, 93431)
        XCTAssertNotNil(vod.vod_play_url)
    }

    // detail 直接返回 Vod（无信封）的形态也要兼容
    func testDetailDecodesDirectVod() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true,
            data: .object([
                "vod_id": .number(5),
                "vod_name": .string("直连片"),
                "vod_play_url": .string("第1集|https://a/1.m3u8")
            ])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(name: "测试", api: "csp_Test", type: 3)

        let vod = try await client.detail(site: site, vodId: "5")
        XCTAssertEqual(vod.vod_name, "直连片")
    }

    // class 键在但数组为空（dm84 宕机实测返回）：应提示源站无响应，而非格式错误
    func testCategoriesEmptyClassGivesSourceSiteHint() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true,
            data: .object(["parse": .number(0), "jx": .number(0), "filters": .object([:]), "list": .array([]), "class": .array([])])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(name: "测试", api: "csp_Test", type: 3)

        do {
            _ = try await client.categories(site: site)
            XCTFail("应当抛出源站无响应错误")
        } catch let error as ManagedAndroidSpiderError {
            guard case .invalidResponse = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssert(error.localizedDescription.contains("源站当前无响应"), "error.localizedDescription = \(error.localizedDescription)")
        }
    }

    // class 键完全缺失：保持原有格式错误信息
    func testCategoriesMissingClassKeepsFormatError() async throws {
        let transport = FakeDexTransport(response: AndroidDexBridgeResponse(
            id: "1", ok: true,
            data: .object(["list": .array([])])
        ))
        let client = ManagedAndroidSpiderClient(transport: transport)
        let site = Site(name: "测试", api: "csp_Test", type: 3)

        do {
            _ = try await client.categories(site: site)
            XCTFail("应当抛出格式错误")
        } catch let error as ManagedAndroidSpiderError {
            guard case .invalidResponse = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssert(error.localizedDescription.contains("缺少 class/type_id/type_name"), "error.localizedDescription = \(error.localizedDescription)")
        }
    }
}