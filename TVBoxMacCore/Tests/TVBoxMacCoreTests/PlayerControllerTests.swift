// PlayerControllerTests.swift — 播放器状态复位与失败上报（离线）
import XCTest
@testable import TVBoxMacCore

@MainActor
final class PlayerControllerTests: XCTestCase {

    /// 换播放地址时必须清掉上一个 item 的派生状态，否则 12s 初始超时守卫
    /// 会读到旧的 bufferedTime，从第二个频道起兜底失效。
    func testPlayResetsDerivedStateFromPreviousItem() {
        let controller = PlayerController()
        controller.bufferedTime = 12.5
        controller.duration = 600
        controller.networkSpeed = 1_000_000
        controller.isBuffering = false

        controller.play(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m3u8"))

        XCTAssertEqual(controller.bufferedTime, 0)
        XCTAssertEqual(controller.duration, 0)
        XCTAssertEqual(controller.networkSpeed, 0)
        XCTAssertTrue(controller.isBuffering)
    }

    /// item.status == .failed 时错误必须能到达 UI（LiveView/PlayerView 都靠它换线）。
    func testFailureAnnouncementPublishesError() {
        let controller = PlayerController()
        controller.announcePlaybackFailure("403 Forbidden")
        XCTAssertEqual(controller.error, "403 Forbidden")

        // 同一错误重复上报不重复发布
        controller.announcePlaybackFailure("403 Forbidden")
        XCTAssertEqual(controller.error, "403 Forbidden")
    }
}
