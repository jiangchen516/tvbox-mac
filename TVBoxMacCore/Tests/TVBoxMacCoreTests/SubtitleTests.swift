// SubtitleTests.swift — SRT 解析（离线）
import XCTest
@testable import TVBoxMacCore

final class SubtitleTests: XCTestCase {
    func testParsesBasicCues() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        你好

        2
        00:01:02,500 --> 00:01:05,000
        第二句
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "你好")
        XCTAssertEqual(cues[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 4, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 62.5, accuracy: 0.001)
    }

    func testKeepsMultiLineTextAndStripsTags() {
        let srt = """
        00:00:05.000 --> 00:00:07.000
        <i>第一行</i>
        第二行
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.first?.text, "第一行\n第二行")
    }

    func testSkipsMalformedBlocks() {
        let srt = """
        没有时间轴的块

        00:00:09,000 --> 00:00:10,000

        00:00:11,000 --> 00:00:12,000
        有效
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.map(\.text), ["有效"])
    }

    func testCueLookup() {
        let cues = [
            SubtitleCue(start: 0, end: 2, text: "a"),
            SubtitleCue(start: 5, end: 7, text: "b"),
        ]
        XCTAssertEqual(SRTParser.cue(at: 1, in: cues)?.text, "a")
        XCTAssertNil(SRTParser.cue(at: 3, in: cues))
        XCTAssertEqual(SRTParser.cue(at: 6.9, in: cues)?.text, "b")
    }
}
