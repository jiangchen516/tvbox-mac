// PlayerLogTests.swift — 播放诊断日志的安全转换（崩溃回归）
import XCTest
@testable import TVBoxMacCore

final class PlayerLogTests: XCTestCase {
    // 实测崩溃：stop() → replaceCurrentItem(nil) → timeControlStatus KVO →
    // Int(player.currentTime().seconds) = Int(NaN) → Swift runtime trap
    func testSafeIntHandlesNonFinite() {
        XCTAssertEqual(PlayerLog.safeInt(.nan), 0, "NaN 不能触发 Int 转换 trap")
        XCTAssertEqual(PlayerLog.safeInt(.infinity), 0)
        XCTAssertEqual(PlayerLog.safeInt(-.infinity), 0)
        XCTAssertEqual(PlayerLog.safeInt(0), 0)
        XCTAssertEqual(PlayerLog.safeInt(12.7), 12)
        XCTAssertEqual(PlayerLog.safeInt(-3.9), -3)
    }

    // 实测崩溃：accessEntrySummary 用 KVC 读不存在的键（numberOfStalls 等）→
    // valueForUndefinedKey 抛 ObjC 异常 → Swift 接不住 → abort
    func testKVDoesNotThrowOnUndefinedKey() {
        XCTAssertNil(PlayerLog.kv(NSObject(), "definitelyNotAKeyHere"))
        XCTAssertNil(PlayerLog.kv(nil, "anything"))
    }

    func testKVReadsExistingKey() {
        // KVC 兼容的自定义属性 → 正常取值
        XCTAssertEqual(PlayerLog.kv(KVStub(), "num") as? Int, 7)
        XCTAssertEqual(PlayerLog.kv(KVStub(), "text") as? String, "hi")
    }

    // 实测：饭太硬原版配置的 config.spider 是相对路径 "./jar/fan.txt;md5;..."，
    // 不解析则 Bridge 下载 jar 失败（Expected URL scheme ... no scheme）
    func testResolveSpiderURL() {
        let fty = "https://raw.githubusercontent.com/qist/tvbox/master/fty.json"
        // 相对路径 + md5 后缀 → 绝对 URL、剥 md5
        XCTAssertEqual(
            resolveSpiderURL("./jar/fan.txt;md5;dab654f794a271c3d7a33d18acfbfa95", against: fty),
            "https://raw.githubusercontent.com/qist/tvbox/master/jar/fan.txt")
        // 无 "./" 前缀的相对路径同样解析
        XCTAssertEqual(resolveSpiderURL("jar/fan.txt", against: fty),
                       "https://raw.githubusercontent.com/qist/tvbox/master/jar/fan.txt")
        // 绝对 URL 原样返回
        XCTAssertEqual(resolveSpiderURL("https://abs.example/x.jar", against: "https://cfg.example/c.json"),
                       "https://abs.example/x.jar")
        // 无 base 时保持原样（本地文件导入场景）
        XCTAssertEqual(resolveSpiderURL("./jar/x.jar", against: nil), "./jar/x.jar")
        // 空值 → nil
        XCTAssertNil(resolveSpiderURL(nil, against: fty))
        XCTAssertNil(resolveSpiderURL("", against: fty))
    }

    func testLogFileIsIsolatedDuringTests() {
        #if canImport(ObjectiveC)
        XCTAssertTrue(PlayerLog.fileURL.path.contains("TVBoxMacTests"),
                      "测试期间日志应写到临时目录：\(PlayerLog.fileURL.path)")
        #endif
    }
}

/// 测试用 KVC 兼容对象
private final class KVStub: NSObject {
    @objc var num: Int = 7
    @objc var text: String = "hi"
}
