import XCTest
@testable import TVBoxMacCore

final class ManagedAndroidRuntimeTests: XCTestCase {
    func testMissingRuntimeIsNotInstalled() {
        let layout = makeLayout()
        XCTAssertEqual(ManagedAndroidRuntimeInspector(layout: layout).inspect(), .notInstalled)
    }

    func testManifestAndExecutableMakeRuntimeReady() throws {
        let layout = makeLayout()
        let manifest = ManagedRuntimeManifest(version: "api35-0.1.0")
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: layout.manifestURL())
        let bridge = layout.bridgeURL(manifest: manifest)
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(),
                             withIntermediateDirectories: true)
        try Data("bridge".utf8).write(to: bridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)

        XCTAssertEqual(ManagedAndroidRuntimeInspector(layout: layout).inspect(),
                       .ready(version: "api35-0.1.0"))
    }

    func testUnsafeBridgePathIsRejected() throws {
        let layout = makeLayout()
        let manifest = ManagedRuntimeManifest(version: "bad", bridgeExecutable: "../bridge")
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: layout.manifestURL())

        XCTAssertEqual(ManagedAndroidRuntimeInspector(layout: layout).inspect(),
                       .invalidManifest("bridgeExecutable 必须是 runtime 目录下的相对路径"))
    }

    func testBridgeRequestRoundTrip() throws {
        let site = Site(name: "测试 Spider", api: "csp_Test", type: 3)
        let request = AndroidDexBridgeRequest(
            id: "r1",
            operation: "detail",
            site: site,
            arguments: ["vodId": .string("42")]
        )
        let decoded = try JSONDecoder().decode(
            AndroidDexBridgeRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
    }

    private func makeLayout() -> ManagedAndroidRuntimeLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-runtime-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return ManagedAndroidRuntimeLayout(root: root)
    }
}
