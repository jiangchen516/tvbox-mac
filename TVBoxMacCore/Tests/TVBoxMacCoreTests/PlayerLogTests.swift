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
}
