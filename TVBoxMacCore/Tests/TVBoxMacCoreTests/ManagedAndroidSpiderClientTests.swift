import XCTest
@testable import TVBoxMacCore

private actor FakeDexTransport: AndroidDexBridgeTransport {
    let response: AndroidDexBridgeResponse

    init(response: AndroidDexBridgeResponse) {
        self.response = response
    }

    func send(_ request: AndroidDexBridgeRequest) async throws -> AndroidDexBridgeResponse {
        return response
    }
}

final class ManagedAndroidSpiderClientTests: XCTestCase {
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
}
