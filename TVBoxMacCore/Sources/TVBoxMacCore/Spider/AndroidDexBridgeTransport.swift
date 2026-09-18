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
        configurationID = "tvboxmac-default"
        hosts = []
        siteKey = request.site.key
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
        providerOwnerID = "tvboxmac-default:\(request.site.id)"
    }

    private static func stringValue(_ value: JSONValue) -> JSONValue {
        .string(value.stringValue ?? "")
    }
}

private struct BridgeInvokeResponse: Decodable {
    let ok: Bool
    let result: JSONValue?
    let error: String?
}
