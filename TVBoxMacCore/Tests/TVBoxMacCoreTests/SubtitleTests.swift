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

extension SubtitleTests {
    func testVTTWithHeaderAndShortTimes() {
        let vtt = """
        WEBVTT

        NOTE 这是注释

        00:01.000 --> 00:03.500 align:start
        <c>你好</c>

        01:00:02.000 --> 01:00:04.000
        第二句
        """
        let cues = SubtitleText.parse(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "你好")
        XCTAssertEqual(cues[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 3602, accuracy: 0.001)
    }

    func testAutoDetectSRT() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n字幕\n"
        XCTAssertEqual(SubtitleText.parse(srt).first?.text, "字幕")
    }

    func testLoaderParsesVTTFromHTTP() async throws {
        struct Stub: HTTPFetching {
            func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
                (Data("WEBVTT\n\n00:00.500 --> 00:02.000\n在线\n".utf8),
                 HTTPResponse(url: url, statusCode: 200))
            }
        }
        let cues = try await SubtitleLoader(http: Stub()).cues(from: URL(string: "https://x.example/a.vtt")!)
        XCTAssertEqual(cues.first?.text, "在线")
    }

    func testLoaderReportsHTTPError() async {
        struct Stub: HTTPFetching {
            func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
                (Data(), HTTPResponse(url: url, statusCode: 403))
            }
        }
        do {
            _ = try await SubtitleLoader(http: Stub()).cues(from: URL(string: "https://x.example/a.srt")!)
            XCTFail("应报 HTTP 403")
        } catch let error as SubtitleLoadError {
            guard case .httpStatus(403) = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testASSParsesDialogueAndStripsTags() {
        let ass = """
        [Script Info]
        Title: 测试
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\an8}第一行\\N第二行
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,普通字幕,带逗号
        """
        let cues = SubtitleText.parse(ass)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "第一行\n第二行")
        XCTAssertEqual(cues[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "普通字幕,带逗号")
    }
}
