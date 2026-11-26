// EPGTests.swift — 直播节目单解析 / URL 模板 / 跨天合并（全离线）
import XCTest
@testable import TVBoxMacCore

private struct EPGStubHTTP: HTTPFetching {
    let handler: @Sendable (URL) async throws -> (Data, HTTPResponse)

    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        try await handler(url)
    }
}

final class EPGTests: XCTestCase {
    private let beijing = EPGClient.beijingTimeZone

    private func beijingDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = beijing
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testMakeURLSubstitutesNameAndDate() throws {
        let day = beijingDate(2026, 11, 26, 12)
        let url = try EPGClient.makeURL(
            template: "https://epg.example/api?ch={NAME}&date=",
            channel: "CCTV-1 综合", day: day)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["ch"], "CCTV-1 综合")
        XCTAssertEqual(items["date"], "2026-11-26")
    }

    func testDecodeHandlesCrossMidnight() throws {
        let json = """
        {"channel_name":"CCTV1","date":"2026-11-26","epg_data":[
          {"start":"20:00","end":"21:30","title":"新闻联播"},
          {"start":"23:30","end":"00:30","title":"深夜档"}
        ]}
        """
        let day = beijingDate(2026, 11, 26)
        let programs = try EPGClient.decode(data: Data(json.utf8), channel: "CCTV1", day: day)
        XCTAssertEqual(programs.map(\.title), ["新闻联播", "深夜档"])
        XCTAssertEqual(programs[1].end.timeIntervalSince(programs[1].start), 3600, accuracy: 1)
    }

    func testScheduleMergesTodayAndTomorrow() async throws {
        let start = beijingDate(2026, 11, 26, 20)
        let stub = EPGStubHTTP { url in
            let date = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "date" })?.value ?? ""
            let body: String
            if date == "2026-11-26" {
                body = #"{"epg_data":[{"start":"20:00","end":"23:59","title":"今晚"}]}"#
            } else {
                body = #"{"epg_data":[{"start":"00:00","end":"08:00","title":"明早"}]}"#
            }
            return (Data(body.utf8), HTTPResponse(url: url, statusCode: 200))
        }
        let client = EPGClient(http: stub)
        let list = try await client.schedule(channel: "CCTV1", template: "https://epg.example/a?ch={NAME}&date=",
                                             from: start, hours: 12)
        XCTAssertEqual(list.map(\.title), ["今晚", "明早"])
    }

    func testProgramsCacheAvoidsSecondRequest() async throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let stub = EPGStubHTTP { url in
            counter.n += 1
            return (Data(#"{"epg_data":[{"start":"10:00","end":"11:00","title":"A"}]}"#.utf8),
                    HTTPResponse(url: url, statusCode: 200))
        }
        let client = EPGClient(http: stub)
        let day = beijingDate(2026, 11, 26)
        _ = try await client.programs(channel: "CCTV1", template: "https://epg.example/a?ch={NAME}&date=", day: day)
        _ = try await client.programs(channel: "CCTV1", template: "https://epg.example/a?ch={NAME}&date=", day: day)
        XCTAssertEqual(counter.n, 1)
    }

    func testHTTPErrorPropagates() async {
        let stub = EPGStubHTTP { url in (Data(), HTTPResponse(url: url, statusCode: 403)) }
        let client = EPGClient(http: stub)
        do {
            _ = try await client.programs(channel: "CCTV1", template: "https://epg.example/a?ch={NAME}&date=",
                                          day: beijingDate(2026, 11, 26))
            XCTFail("应报 HTTP 403")
        } catch let error as EPGError {
            guard case .httpStatus(403) = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testChannelAliasCandidates() {
        let candidates = EPGChannelAliases.candidates(for: "CCTV-1 综合高清")
        XCTAssertTrue(candidates.contains("CCTV-1 综合高清"))
        XCTAssertTrue(candidates.contains("CCTV1"))
        XCTAssertTrue(candidates.contains("CCTV-1"))
    }

    func testPlaceholderTitles() {
        XCTAssertTrue(EPGChannelAliases.isPlaceholder(title: "精彩节目-暂未提供节目预告信息 --免费使用"))
        XCTAssertFalse(EPGChannelAliases.isPlaceholder(title: "新闻联播"))
    }
}
