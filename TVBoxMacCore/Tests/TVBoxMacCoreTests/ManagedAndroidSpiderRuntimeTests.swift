import XCTest
@testable import TVBoxMacCore

final class ManagedAndroidSpiderRuntimeTests: XCTestCase {
    func testStopWithoutStartIsSafeAndIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-runtime-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ManagedAndroidRuntimeController(
            sdkRoot: root.appendingPathComponent("sdk"),
            avdName: "TestAVD",
            avdHome: root.appendingPathComponent("avd"),
            userHome: root.appendingPathComponent("home")
        )
        let runtime = ManagedAndroidSpiderRuntime(
            controller: controller,
            bridgeAPK: root.appendingPathComponent("bridge.apk")
        )
        await runtime.stop()
        await runtime.stop()
    }
}
