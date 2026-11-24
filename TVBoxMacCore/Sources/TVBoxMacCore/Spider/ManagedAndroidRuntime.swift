import Foundation

public struct ManagedRuntimeManifest: Codable, Sendable, Equatable {
    public let version: String
    public let architecture: String
    public let bridgeExecutable: String
    public let sha256: String?

    public init(version: String, architecture: String = "arm64",
                bridgeExecutable: String = "bridge/TVBoxDexBridge",
                sha256: String? = nil) {
        self.version = version
        self.architecture = architecture
        self.bridgeExecutable = bridgeExecutable
        self.sha256 = sha256
    }
}

public enum ManagedAndroidRuntimeState: Sendable, Equatable {
    case unsupportedArchitecture
    case notInstalled
    case invalidManifest(String)
    case ready(version: String)
}

public enum ManagedAndroidRuntimeError: LocalizedError, Sendable {
    case unsupportedArchitecture
    case invalidManifest(String)
    case notInstalled
    case bridgeUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "内置 Android Runtime 仅支持 Apple Silicon"
        case .invalidManifest(let message):
            return "Android Runtime 清单无效: \(message)"
        case .notInstalled:
            return "Android Runtime 尚未安装"
        case .bridgeUnavailable:
            return "Android Dex Bridge 不可用"
        }
    }
}

public struct ManagedAndroidRuntimeLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL? = nil,
                fileManager: FileManager = .default) {
        self.root = root ?? fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMac/managed-android-runtime", isDirectory: true)
    }

    public func manifestURL() -> URL {
        root.appendingPathComponent("runtime.json")
    }

    public func bridgeURL(manifest: ManagedRuntimeManifest) -> URL {
        root.appendingPathComponent(manifest.bridgeExecutable)
    }
}

public struct ManagedAndroidRuntimeInspector: Sendable {
    public let layout: ManagedAndroidRuntimeLayout

    public init(layout: ManagedAndroidRuntimeLayout = .init()) {
        self.layout = layout
    }

    public func inspect() -> ManagedAndroidRuntimeState {
        guard Self.isSupportedArchitecture else { return .unsupportedArchitecture }
        guard let data = try? Data(contentsOf: layout.manifestURL()) else {
            return .notInstalled
        }
        guard let manifest = try? JSONDecoder().decode(ManagedRuntimeManifest.self, from: data) else {
            return .invalidManifest("runtime.json 不是有效 JSON")
        }
        guard Self.isValidRelativePath(manifest.bridgeExecutable) else {
            return .invalidManifest("bridgeExecutable 必须是 runtime 目录下的相对路径")
        }
        guard FileManager.default.isExecutableFile(atPath: layout.bridgeURL(manifest: manifest).path) else {
            return .invalidManifest("Bridge 可执行文件不存在或不可执行")
        }
        return .ready(version: manifest.version)
    }

    public static var isSupportedArchitecture: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static func isValidRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

public struct AndroidDexBridgeRequest: Codable, Sendable, Equatable {
    public let id: String
    public let operation: String
    public let site: Site
    public let arguments: [String: JSONValue]

    public init(id: String = UUID().uuidString, operation: String, site: Site,
                arguments: [String: JSONValue] = [:]) {
        self.id = id
        self.operation = operation
        self.site = site
        self.arguments = arguments
    }
}

public struct AndroidDexBridgeResponse: Codable, Sendable, Equatable {
    public let id: String
    public let ok: Bool
    public let data: JSONValue?
    public let error: String?

    public init(id: String, ok: Bool, data: JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.data = data
        self.error = error
    }
}

public protocol AndroidDexBridgeTransport: Sendable {
    func send(_ request: AndroidDexBridgeRequest) async throws -> AndroidDexBridgeResponse
    /// 重启托管运行时（模拟器 + Bridge）。用于恢复模拟器内 DNS/网络失效等卡死状态。
    func restart() async throws
}

public extension AndroidDexBridgeTransport {
    /// 默认不重启（测试/自定义 transport 只需实现 send）
    func restart() async throws {}
}

public actor ManagedAndroidRuntime {
    public let layout: ManagedAndroidRuntimeLayout
    private let inspector: ManagedAndroidRuntimeInspector

    public init(layout: ManagedAndroidRuntimeLayout = .init()) {
        self.layout = layout
        self.inspector = ManagedAndroidRuntimeInspector(layout: layout)
    }

    public func state() -> ManagedAndroidRuntimeState {
        inspector.inspect()
    }

    public func requireReady() throws {
        switch inspector.inspect() {
        case .ready:
            return
        case .unsupportedArchitecture:
            throw ManagedAndroidRuntimeError.unsupportedArchitecture
        case .notInstalled:
            throw ManagedAndroidRuntimeError.notInstalled
        case .invalidManifest(let message):
            throw ManagedAndroidRuntimeError.invalidManifest(message)
        }
    }
}
