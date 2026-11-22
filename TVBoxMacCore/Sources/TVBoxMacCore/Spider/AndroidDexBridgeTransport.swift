import Foundation

/// HTTP transport for the Bridge exposed through an ADB loopback forward.
/// The Android process listens on guest loopback; the macOS runtime maps it to
/// this host port after it has verified emulator ownership.
public actor AndroidDexBridgeHTTPTransport: AndroidDexBridgeTransport {
    public let baseURL: URL
    private let session: URLSession

    public init(hostPort: Int = 19_978) {
        self.baseURL = URL(string: "http://127.0.0.1:\(hostPort)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 65
        configuration.timeoutIntervalForResource = 70
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: AndroidDexBridgeRequest) async throws -> AndroidDexBridgeResponse {
        let url = baseURL.appendingPathComponent("v1/invoke")
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.timeoutInterval = 65
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONEncoder().encode(BridgeInvokeRequest(request: request))

        let (data, response) = try await session.data(for: httpRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AndroidDexBridgeTransportError.httpStatus(status, String(data: data, encoding: .utf8) ?? "")
        }
        let bridgeResponse: BridgeInvokeResponse
        do {
            bridgeResponse = try JSONDecoder().decode(BridgeInvokeResponse.self, from: data)
        } catch {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<binary>"
            throw AndroidDexBridgeTransportError.invalidResponse(
                "JSON 解码失败（HTTP=\(status), bytes=\(data.count)）：\(error.localizedDescription)；响应前缀=\(preview)"
            )
        }
        return AndroidDexBridgeResponse(
            id: request.id,
            ok: bridgeResponse.ok,
            data: bridgeResponse.result,
            error: bridgeResponse.error
        )
    }
}

public enum AndroidDexBridgeTransportError: LocalizedError, Sendable {
    case httpStatus(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let body):
            return "Android Dex Bridge HTTP \(status): \(String(body.prefix(500)))"
        case .invalidResponse(let message):
            return "Android Dex Bridge 响应无效: \(message)"
        }
    }
}

private struct BridgeInvokeRequest: Encodable {
    let configurationID: String
    let hosts: [String]
    let siteKey: String
    let api: String
    let ext: String
    let jarURL: String
    let jarMD5: String
    let method: String
    let arguments: [JSONValue]
    let monitorsAuthorization: Bool
    let interactionID: String?
    let interactionKind: String?
    let providerOwnerID: String

    init(request: AndroidDexBridgeRequest) {
        // Bridge 按 configurationID + siteKey 缓存 spider 实例。固定写成一个
        // tvboxmac-default 会让 30 份配置、1771 个站点互相污染：同名 Wogg/Nmyswv
        // 切换后可能复用旧 jar/旧 ext，Android 端通常每份配置使用独立 ID。
        let scope = Self.scope(for: request.site)
        configurationID = "tvboxmac-\(scope)"
        hosts = []
        siteKey = request.site.key.isEmpty ? request.site.api : request.site.key
        api = request.site.api
        ext = request.site.ext.map { value in
            if case .string(let string) = value { return string }
            return String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? ""
        } ?? ""
        jarURL = request.site.jar ?? ""
        jarMD5 = ""
        switch request.operation {
        case "categories":
            method = "home"
        case "browse":
            method = "category"
        default:
            method = request.operation
        }
        switch request.operation {
        case "categories":
            arguments = [.bool(true)]
        case "browse":
            arguments = [
                request.arguments["category"] ?? .string(""),
                request.arguments["page"].map(Self.stringValue) ?? .string("1"),
                request.arguments["filter"] ?? .bool(false),
                .object([:])
            ]
        case "search":
            arguments = [
                request.arguments["keyword"] ?? .string(""),
                .bool(false),
                request.arguments["page"].map(Self.stringValue) ?? .string("1")
            ]
        case "detail":
            arguments = [.array([request.arguments["vodId"].map(Self.stringValue) ?? .string("0")])]
        case "play":
            let episode: [String: JSONValue]
            if case .object(let value)? = request.arguments["episode"] {
                episode = value
            } else {
                episode = [:]
            }
            arguments = [
                episode["group"] ?? .string(""),
                episode["url"] ?? .string(""),
                .array([])
            ]
        default:
            arguments = []
        }
        monitorsAuthorization = false
        interactionID = nil
        interactionKind = nil
        providerOwnerID = "tvboxmac-\(scope):\(request.site.id)"
    }

    private static func stringValue(_ value: JSONValue) -> JSONValue {
        .string(value.stringValue ?? "")
    }

    private static func scope(for site: Site) -> String {
        let ext = site.ext.map { String(describing: $0) } ?? "-"
        let raw = "\(site.jar ?? "-")|\(site.api)|\(ext)"
        // Stable FNV-1a hash；不把完整 URL/ext 放进 Bridge ID，避免超长或特殊字符。
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private struct BridgeInvokeResponse: Decodable {
    let ok: Bool
    let result: JSONValue?
    let error: String?
}
