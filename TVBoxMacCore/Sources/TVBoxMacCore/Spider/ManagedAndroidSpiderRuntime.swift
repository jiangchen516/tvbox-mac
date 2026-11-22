import Foundation

/// Lazy bridge transport: the emulator and Bridge APK are started only when a
/// Java/Dex site is actually requested. Native CatVod/JS paths do not pay this
/// startup cost.
public actor ManagedAndroidSpiderRuntime: AndroidDexBridgeTransport {
    private let controller: ManagedAndroidRuntimeController
    private let transport: AndroidDexBridgeHTTPTransport
    private let bridgeAPK: URL
    private var started = false
    private var preparationTask: Task<Void, Error>?

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

    /// 仅启动 Emulator、安装/启动 Bridge 并建立端口转发，不发起任何站点请求。
    /// 可由用户选择在 App 启动后后台调用，减少第一次打开 csp_ 源的冷启动等待。
    public func prepare() async throws {
        if started { return }
        if let preparationTask {
            try await preparationTask.value
            started = true
            return
        }

        let controller = self.controller
        let bridgeAPK = self.bridgeAPK
        let task = Task { try await controller.start(bridgeAPK: bridgeAPK) }
        preparationTask = task
        do {
            try await task.value
            started = true
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    public func send(_ request: AndroidDexBridgeRequest) async throws -> AndroidDexBridgeResponse {
        try await prepare()
        return try await transport.send(request)
    }

    public func stop() async {
        if let preparationTask {
            preparationTask.cancel()
            _ = try? await preparationTask.value
        }
        await controller.stop()
        preparationTask = nil
        started = false
    }
}
