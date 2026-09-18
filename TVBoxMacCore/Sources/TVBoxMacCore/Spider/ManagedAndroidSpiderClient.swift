import Foundation

public enum ManagedAndroidSpiderError: LocalizedError, Sendable {
    case runtimeUnavailable
    case bridge(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Android Dex Runtime 不可用"
        case .bridge(let message):
            return "Android Dex Bridge 错误: \(message)"
        case .invalidResponse(let message):
            return "Android Dex Bridge 响应无效: \(message)"
        }
    }
}

public actor ManagedAndroidSpiderClient: VodFetching {
    private let transport: any AndroidDexBridgeTransport
    private var globalSpiderURL: String?

    public init(transport: any AndroidDexBridgeTransport) {
        self.transport = transport
    }

    public func setGlobalSpiderURL(_ url: String?) {
        globalSpiderURL = url
    }

    public func categories(site: Site) async throws -> [String] {
        let data = try await call(operation: "categories", site: site)
        let response = try decode(BridgeCategoriesResponse.self, from: data)
        return response.categories
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
        try await callDecoded(operation: "browse", site: site,
                              arguments: [
                                "category": .string(category ?? ""),
                                "page": .number(Double(page))
                              ])
    }

    public func search(site: Site, keyword: String, page: Int) async throws -> VodPage {
        try await callDecoded(operation: "search", site: site,
                              arguments: [
                                "keyword": .string(keyword),
                                "page": .number(Double(page))
                              ])
    }

    public func detail(site: Site, vodId: Int) async throws -> Vod {
        try await callDecoded(operation: "detail", site: site,
                              arguments: ["vodId": .number(Double(vodId))])
    }

    public func resolvePlayUrl(site: Site, vod: Vod, episode: Episode) async throws -> String {
        let data = try await call(operation: "play", site: site, arguments: [
            "vod": try jsonValue(vod),
            "episode": try jsonValue(episode)
        ])
        let response = try decode(BridgePlayResponse.self, from: data)
        guard !response.url.isEmpty else {
            throw ManagedAndroidSpiderError.invalidResponse("播放响应缺少 url")
        }
        return response.url
    }

    private func callDecoded<Response: Decodable>(
        operation: String,
        site: Site,
        arguments: [String: JSONValue]
    ) async throws -> Response {
        try decode(Response.self, from: try await call(operation: operation, site: site,
                                                        arguments: arguments))
    }

    private func call(
        operation: String,
        site: Site,
        arguments: [String: JSONValue] = [:]
    ) async throws -> Data {
        var resolvedSite = site
        if resolvedSite.jar == nil || resolvedSite.jar?.isEmpty == true {
            resolvedSite.jar = globalSpiderURL
        }
        let request = AndroidDexBridgeRequest(operation: operation, site: resolvedSite, arguments: arguments)
        let response: AndroidDexBridgeResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ManagedAndroidSpiderError.bridge(error.localizedDescription)
        }
        guard response.ok else {
            throw ManagedAndroidSpiderError.bridge(response.error ?? "未知错误")
        }
        guard let value = response.data,
              JSONSerialization.isValidJSONObject(value.asAny) else {
            throw ManagedAndroidSpiderError.invalidResponse("缺少可解码 data")
        }
        return try JSONSerialization.data(withJSONObject: value.asAny)
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ManagedAndroidSpiderError.invalidResponse(error.localizedDescription)
        }
    }

    private func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        } catch {
            throw ManagedAndroidSpiderError.invalidResponse("请求参数编码失败")
        }
    }
}

private struct BridgeCategoriesResponse: Decodable {
    let categories: [String]
}

private struct BridgePlayResponse: Decodable {
    let url: String
}
