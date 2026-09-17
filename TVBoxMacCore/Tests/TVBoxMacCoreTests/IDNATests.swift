// IDNA.swift — IDN host 归一化测试
// 纯 Swift Punycode 兜底后两平台行为一致（都出真 punycode），
// 标准答案对拍：python3 -c "print('饭太硬'.encode('punycode'))" == sss604efuw
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

    func testUrlStringChineseHost() {
        // 纯字符串处理，两平台一致（ICU 可用时走 ICU，缺失时走手写 Punycode，结果相同）
        XCTAssertEqual(IDNA.urlString("http://www.饭太硬.net/tv"), "http://www.xn--sss604efuw.net/tv")
        XCTAssertEqual(IDNA.urlString("http://www.饭太硬.net"), "http://www.xn--sss604efuw.net")
    }

    func testChineseHost() throws {
        XCTAssertEqual(IDNA.idnHost("www.饭太硬.net"), "www.xn--sss604efuw.net")
        XCTAssertEqual(IDNA.idnHost("饭太硬.tv"), "xn--sss604efuw.tv")
        let u = URL(string: "http://www.饭太硬.net/tv")!
        XCTAssertEqual(IDNA.url(u).host, "www.xn--sss604efuw.net")
        XCTAssertEqual(IDNA.url(u).path, "/tv")
        let u2 = URL(string: "https://www.饭太硬.net/api?ac=detail&pg=1")!
        let n2 = IDNA.url(u2)
        XCTAssertEqual(n2.host, "www.xn--sss604efuw.net")
        XCTAssertEqual(n2.path, "/api")
    }

    // 注意：Linux 上 URL(string:) 对非 ASCII host 返回 nil，url 入口无法构造；
    // 但 Punycode/IDNA 是纯字符串层，两平台都可测。
    func testPunycodeStandardVectors() throws {
        // 与 Python stdlib punycode 对拍的标准向量
        XCTAssertEqual(try Punycode.encode("饭太硬"), "sss604efuw")
        XCTAssertEqual(try Punycode.encode("西a"), "a-cj1d")
        XCTAssertEqual(try Punycode.encode("中"), "fiq")
        XCTAssertEqual(try Punycode.encode("bücher"), "bcher-kva")
        XCTAssertEqual(try Punycode.encode("münchen"), "mnchen-3ya")
        // 连字符在 basic 部分（与 Python 'abc-中文'.encode('punycode') 一致）
        XCTAssertEqual(try Punycode.encode("abc-中文"), "abc--3f5fy05j")
        // 域名级
        XCTAssertEqual(Punycode.toASCII("www.饭太硬.net"), "www.xn--sss604efuw.net")
        XCTAssertEqual(Punycode.toASCII("饭太硬.tv"), "xn--sss604efuw.tv")
        XCTAssertEqual(Punycode.toASCII("中文.com"), "xn--fiq228c.com")
        XCTAssertEqual(Punycode.toASCII("abc-中文.com"), "xn--abc--3f5fy05j.com")
        XCTAssertEqual(Punycode.toASCII("example.com"), "example.com")
        // RFC 3490 扩展分隔符（'。''．''｡' 按 '.' 处理）
        XCTAssertEqual(Punycode.toASCII("a。b"), "a.b")
        XCTAssertEqual(Punycode.toASCII("饭太硬."), "xn--sss604efuw.")
    }
}
