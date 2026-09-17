// IDNA.swift — IDN host 归一化测试
// macOS：Apple CFStringTransform 真实 IDNA（标准答案对拍：'饭太硬'.encode('punycode') == sss604efuw）
// Linux：passthrough，且 Linux URL(string:) 对非 ASCII host 直接返回 nil（与 macOS 行为不同）
import XCTest
@testable import TVBoxMacCore

final class IDNATests: XCTestCase {
    func testAsciiHostUnchanged() {
        XCTAssertEqual(IDNA.idnHost("example.com"), "example.com")
        XCTAssertEqual(IDNA.idnHost("sub.domain.example.com"), "sub.domain.example.com")
    }

    func testAsciiUrlUnchanged() throws {
        let u = URL(string: "https://example.com/vod?ac=detail")!
        XCTAssertEqual(IDNA.url(u), u)
        XCTAssertEqual(IDNA.urlString("https://example.com/x?b=c"), "https://example.com/x?b=c")
        // 无 path 形式
        XCTAssertEqual(IDNA.urlString("https://example.com"), "https://example.com")
        // 带端口
        XCTAssertEqual(IDNA.urlString("http://a.com:8080/p"), "http://a.com:8080/p")
    }

    func testUrlStringChineseHost() throws {
        // urlString 是纯字符串处理，两平台都验证（macOS 真转换 / Linux passthrough）
        #if os(macOS)
        XCTAssertEqual(IDNA.urlString("http://www.饭太硬.net/tv"), "http://www.xn--sss604efuw.net/tv")
        XCTAssertEqual(IDNA.urlString("http://www.饭太硬.net"), "http://www.xn--sss604efuw.net")
        #else
        XCTAssertEqual(IDNA.urlString("http://www.饭太硬.net/tv"), "http://www.饭太硬.net/tv")
        #endif
    }

    func testChineseHost() throws {
        #if os(macOS)
        XCTAssertEqual(IDNA.idnHost("www.饭太硬.net"), "www.xn--sss604efuw.net")
        XCTAssertEqual(IDNA.idnHost("饭太硬.tv"), "xn--sss604efuw.tv")
        let u = URL(string: "http://www.饭太硬.net/tv")!
        XCTAssertEqual(IDNA.url(u).host, "www.xn--sss604efuw.net")
        XCTAssertEqual(IDNA.url(u).path, "/tv")
        let u2 = URL(string: "https://www.饭太硬.net/api?ac=detail&pg=1")!
        let n2 = IDNA.url(u2)
        XCTAssertEqual(n2.host, "www.xn--sss604efuw.net")
        XCTAssertEqual(n2.path, "/api")
        #else
        // Linux：URL(string:) 对非 ASCII host 返回 nil，IDNA.url 对 nil 场景无从介入；
        // 只验证 ASCII 路径与 passthrough 语义
        XCTAssertEqual(IDNA.idnHost("www.饭太硬.net"), "www.饭太硬.net")
        let u = URL(string: "http://example.com/tv")!
        XCTAssertEqual(IDNA.url(u).path, "/tv")
        #endif
    }
}
