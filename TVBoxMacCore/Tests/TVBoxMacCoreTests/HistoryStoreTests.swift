// HistoryStoreTests.swift — 历史 / 收藏
import XCTest
@testable import TVBoxMacCore

final class HistoryStoreTests: XCTestCase {

    func testHistoryAddAndRecent() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvboxtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = HistoryStore(directory: tmp, maxHistory: 3)
        for i in 1...5 {
            await store.addHistory(HistoryRecord(site: "s", vodId: i, vodName: "剧\(i)",
                                                 episodeTitle: "第1集", episodeGroup: "直连",
                                                 position: 10.0))
        }
        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.count, 3)          // 上限 3 截断
        XCTAssertEqual(recent[0].vodId, 5)       // 最新的在前

        // 重复 id 不重复插入
        await store.addHistory(HistoryRecord(site: "s", vodId: 5, vodName: "剧5",
                                             episodeTitle: "第1集", episodeGroup: "直连",
                                             position: 99.0))
        let again = await store.recent(limit: 10)
        XCTAssertEqual(again.count, 3)
        XCTAssertEqual(again[0].position, 99.0)

        // 断点续播查询
        let pos = await store.positionFor(site: "s", vodId: 5)
        XCTAssertEqual(pos?.position, 99.0)
        let missing = await store.positionFor(site: "s", vodId: 999)
        XCTAssertNil(missing)
    }

    func testHistoryPersistenceRoundtrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvboxtest-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(directory: tmp)
        await store.addHistory(HistoryRecord(site: "s", vodId: 7, vodName: "持久化",
                                             episodeTitle: "第2集", episodeGroup: "g",
                                             position: 42.0))
        // 新实例读盘
        let store2 = HistoryStore(directory: tmp)
        let recent = await store2.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].vodName, "持久化")
        await store2.clearHistory()
        let after = await store2.recent()
        XCTAssertTrue(after.isEmpty)
    }

    func testFavorites() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvboxtest-\(UUID().uuidString)", isDirectory: true)
        let store = HistoryStore(directory: tmp)

        let f0 = await store.isFavorite(id: "s#1")
        XCTAssertFalse(f0)
        await store.addFavorite(Favorite(site: "s", vodId: 1, vodName: "收藏1"))
        await store.addFavorite(Favorite(site: "s", vodId: 2, vodName: "收藏2"))
        let f1 = await store.isFavorite(id: "s#1")
        XCTAssertTrue(f1)
        let favs = await store.favorites()
        XCTAssertEqual(favs.count, 2)

        await store.removeFavorite(id: "s#1")
        let f2 = await store.isFavorite(id: "s#1")
        XCTAssertFalse(f2)
        let favs2 = await store.favorites()
        XCTAssertEqual(favs2.count, 1)
    }
}
