// ParseRuleTests.swift — parse 规则引擎
import XCTest
@testable import TVBoxMacCore

final class ParseRuleTests: XCTestCase {

    func testType0TemplatePlaceholder() throws {
        let rule = ParseRule(name: "t", url: "https://proxy.example.com/play/{url}")
        let out = ParseRuleEngine.concatTemplate(rule.url, url: "https://cdn/a.m3u8")
        XCTAssertEqual(out, "https://proxy.example.com/play/https://cdn/a.m3u8")
    }

    func testType0TemplateAppend() throws {
        // 无占位符 → 拼接
        let out = ParseRuleEngine.concatTemplate("https://proxy.example.com/play", url: "https://cdn/a.m3u8")
        XCTAssertEqual(out, "https://proxy.example.com/play/https://cdn/a.m3u8")
    }

    func testBuildParseUrlWithExt() {
        // ext 对象 → base64url → cat_ext 参数
        let ext = JSONValue.object(["token": .string("abc")])
        let out = ParseRuleEngine.buildParseUrl("https://p.example.com/api", ext: ext)
        XCTAssertTrue(out.hasPrefix("https://p.example.com/api?cat_ext="), out)
        // 还原 cat_ext 应能解出 token
        let b64 = out.components(separatedBy: "cat_ext=").last!
        let norm = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = norm + String(repeating: "=", count: (4 - norm.count % 4) % 4)
        if let d = Data(base64Encoded: padded), let s = String(data: d, encoding: .utf8) {
            XCTAssertTrue(s.contains("token"), s)
        } else {
            XCTFail("cat_ext base64url 解码失败: \(b64)")
        }
    }

    func testBuildParseUrlNoExt() {
        let out = ParseRuleEngine.buildParseUrl("https://p.example.com/api", ext: nil)
        XCTAssertEqual(out, "https://p.example.com/api")
    }

    func testExtractPlayUrlFromBareUrl() throws {
        let data = Data("https://cdn.example.com/real.m3u8".utf8)
        let out = try ParseRuleEngine.extractPlayUrl(from: data, ext: nil)
        XCTAssertEqual(out, "https://cdn.example.com/real.m3u8")
    }

    func testExtractPlayUrlFromJsonField() throws {
        let data = Data(#"{"url": "https://cdn.example.com/x.m3u8"}"#.utf8)
        let out = try ParseRuleEngine.extractPlayUrl(from: data, ext: nil)
        XCTAssertEqual(out, "https://cdn.example.com/x.m3u8")
    }

    func testExtractPlayUrlFromNestedPath() throws {
        let data = Data(#"{"data": {"url": "https://cdn.example.com/y.m3u8", "other": 1}}"#.utf8)
        let ext = JSONValue.object(["parse": .string("data.url")])
        let out = try ParseRuleEngine.extractPlayUrl(from: data, ext: ext)
        XCTAssertEqual(out, "https://cdn.example.com/y.m3u8")
    }

    func testExtractPlayUrlNotFoundThrows() {
        let data = Data(#"{"foo": "bar"}"#.utf8)
        XCTAssertThrowsError(try ParseRuleEngine.extractPlayUrl(from: data, ext: nil))
    }

    // MARK: - 端到端（mock HTTP）

    func testResolveType1ViaMock() async throws {
        final class Mock: HTTPFetching {
            var lastUrl: String = ""
            var lastHeaders: [String: String]?
            func get(_ url: URL, headers: [String: String]?) async throws
                -> (data: Data, response: HTTPResponse) {
                lastUrl = url.absoluteString
                lastHeaders = headers
                return (Data(#"{"url":"https://cdn.example.com/final.m3u8"}"#.utf8),
                        HTTPResponse(url: url, statusCode: 200))
            }
        }
        let mock = Mock()
        let engine = ParseRuleEngine(http: mock)
        let rule = ParseRule(name: "p", url: "https://p.example.com/api", type: 1)
        let out = try await engine.resolve(url: "https://raw.example.com/a.m3u8",
                                           rule: rule,
                                           siteHeader: ["Referer": "https://tv.example.com"],
                                           globalHeader: [:],
                                           ua: "okhttp/3.10.0")
        XCTAssertEqual(out, "https://cdn.example.com/final.m3u8")
        // mock 非 HttpClient → 走 GET &url= 回退分支
        XCTAssertTrue(mock.lastUrl.hasPrefix("https://p.example.com/api?url="), mock.lastUrl)
        XCTAssertEqual(mock.lastHeaders?["Referer"], "https://tv.example.com")
        XCTAssertEqual(mock.lastHeaders?["User-Agent"], "okhttp/3.10.0")
    }

    func testResolveNilRuleReturnsOriginal() async throws {
        let engine = ParseRuleEngine(http: NoopHTTP())
        let out = try await engine.resolve(url: "https://cdn/a.m3u8", rule: nil)
        XCTAssertEqual(out, "https://cdn/a.m3u8")
    }
}

/// 不应被调用的 mock
final class NoopHTTP: HTTPFetching {
    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse) {
        XCTFail("noop 不应被调用")
        return (Data(), HTTPResponse(url: url, statusCode: 200))
    }
}
