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
}

/// 测试用 KVC 兼容对象
private final class KVStub: NSObject {
    @objc var num: Int = 7
    @objc var text: String = "hi"
}
