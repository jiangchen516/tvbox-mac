// DownloadTests.swift — 下载器播放列表解析（离线）
import XCTest
@testable import TVBoxMacCore

final class DownloadTests: XCTestCase {
    func testMasterPicksHighestBandwidth() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1920x1080
        high/index.m3u8
        """
        let url = DownloadManager.bestVariant(in: text, base: URL(string: "https://cdn.example/master.m3u8")!)
        XCTAssertEqual(url?.absoluteString, "https://cdn.example/high/index.m3u8")
    }

    func testMediaPlaylistParsesSegmentsAndDurations() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXTINF:9.009,
        seg0.ts
        #EXTINF:8.5,
        https://cdn.example/seg1.ts
        #EXT-X-ENDLIST
        """
        let items = try DownloadManager.parseMediaPlaylist(
            text, base: URL(string: "https://cdn.example/path/index.m3u8")!)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].duration, 9.009, accuracy: 0.001)
        XCTAssertEqual(items[0].url.absoluteString, "https://cdn.example/path/seg0.ts")
        XCTAssertEqual(items[1].url.absoluteString, "https://cdn.example/seg1.ts")
    }

    func testEncryptedPlaylistDetected() {
        XCTAssertTrue(DownloadManager.isEncrypted("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.bin\""))
        XCTAssertFalse(DownloadManager.isEncrypted("#EXTM3U\n#EXT-X-KEY:METHOD=NONE"))
    }

    func testSanitizeTitle() {
        XCTAssertEqual(DownloadManager.sanitize("片名/第1集: 试看"), "片名-第1集- 试看")
    }
}
