// ConfigLoaderTests.swift — 配置加载（本地文件 URL，不联网）
import XCTest
@testable import TVBoxMacCore

final class ConfigLoaderTests: XCTestCase {

    private func fixtureURL(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: ext)!
    }

    func testLoadSingleConfig() throws {
        let url = fixtureURL("sample-config", "json")
        let config = try ConfigLoader.load(localFile: url)
        XCTAssertEqual(config.sites.count, 3)
        XCTAssertEqual(config.sites[0].key, "fty")
        XCTAssertEqual(config.sites[0].name, "饭太硬")
        XCTAssertEqual(config.sites[0].type, 1)
        XCTAssertEqual(config.sites[2].type, 0)          // spider 站
        XCTAssertEqual(config.parses.count, 2)
        XCTAssertEqual(config.parses[0].type, 1)
        XCTAssertEqual(config.flags, ["优酷", "爱奇艺"])
        // header 字符串解析
        let h = HeaderParser.parse(config.header)
        XCTAssertEqual(h["User-Agent"], "okhttp/3.10.0")
        XCTAssertEqual(h["Referer"], "https://tvbox.example.com")
    }

    func testMalformedConfigThrows() {
        let url = fixtureURL("malformed-config", "json")
        XCTAssertThrowsError(try ConfigLoader.load(localFile: url)) { error in
            guard case ConfigLoaderError.noSites = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }
    }

    func testAggregateJsonShape() throws {
        // 聚合列表结构解析（不实际展开，展开需要网络）
        let url = fixtureURL("sample-aggregate", "json")
        let data = try Data(contentsOf: url)
        let list = try JSONDecoder().decode(AggregateList.self, from: data)
        XCTAssertEqual(list.urls.count, 5)
        XCTAssertEqual(list.urls[0].name, "🚀游魂┃饭太硬")
        XCTAssertTrue(list.urls[0].url.hasPrefix("https://"))
    }

    func testConfigStoreRoundtrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvboxtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ConfigStore(directory: tmp)
        let config = TVBoxConfig(sites: [Site(key: "k", name: "测试站", api: "https://a.com/")])
        let loaded = LoadedConfig(name: "测试站", url: "local:测试.json", config: config)

        var entries = try await store.add(loaded)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].loaded.enabled)

        entries = try await store.remove(id: loaded.id)
        XCTAssertEqual(entries.count, 0)

        _ = try await store.add(loaded)
        entries = try await store.setEnabled(id: loaded.id, enabled: false)
        XCTAssertEqual(entries[0].loaded.enabled, false)

        // 重新开一个 store 实例，验证持久化落盘
        let store2 = ConfigStore(directory: tmp)
        let reloaded = try await store2.load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].loaded.name, "测试站")
        XCTAssertEqual(reloaded[0].loaded.config.sites.first?.key, "k")
    }
}
