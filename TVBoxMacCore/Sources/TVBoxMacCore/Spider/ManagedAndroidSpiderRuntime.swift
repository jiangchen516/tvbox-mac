import Foundation

/// Lazy bridge transport: the emulator and Bridge APK are started only when a
/// Java/Dex site is actually requested. Native CatVod/JS paths do not pay this
/// startup cost.
public actor ManagedAndroidSpiderRuntime: AndroidDexBridgeTransport {
    private let controller: ManagedAndroidRuntimeController
    private let transport: AndroidDexBridgeHTTPTransport
    private let bridgeAPK: URL
    private var started = false

    public init(
        controller: ManagedAndroidRuntimeController,
        bridgeAPK: URL,
        transport: AndroidDexBridgeHTTPTransport? = nil
    ) {
        self.controller = controller
        self.bridgeAPK = bridgeAPK
        self.transport = transport ?? AndroidDexBridgeHTTPTransport(
            hostPort: controller.hostBridgePort
        )
    }

    public func send(_ request: AndroidDexBridgeRequest) async throws -> AndroidDexBridgeResponse {
        if !started {
            try await controller.start(bridgeAPK: bridgeAPK)
            started = true
        }
        return try await transport.send(request)
    }

    public func stop() async {
        await controller.stop()
        started = false
    }
}
