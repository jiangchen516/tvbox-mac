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
    private var categoryIDs: [String: [String: String]] = [:]

    public init(transport: any AndroidDexBridgeTransport) {
        self.transport = transport
    }

    public func setGlobalSpiderURL(_ url: String?) {
        globalSpiderURL = url
    }

    public func categories(site: Site) async throws -> [String] {
        let data = try await call(operation: "categories", site: site)
        let response = try decodeCategoryResponse(from: data)
        categoryIDs[site.id] = response.ids
        return response.names
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
                let displayCategory = category ?? ""
                let resolvedCategory = categoryIDs[site.id]?[displayCategory] ?? displayCategory
                do {
                        return try await browse(site: site, categoryValue: resolvedCategory, page: page)
                } catch let error as ManagedAndroidSpiderError
                                        where displayCategory != resolvedCategory
                                        && error.localizedDescription.localizedCaseInsensitiveContains("category invalid") {
                        // Some legacy spiders expose names instead of numeric type IDs.
                        return try await browse(site: site, categoryValue: displayCategory, page: page)
                }
    }

        private func browse(site: Site, categoryValue: String, page: Int) async throws -> VodPage {
                try await callDecoded(operation: "browse", site: site,
                                                            arguments: [
                                                                "category": .string(categoryValue),
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
        guard let value = response.data else {
            throw ManagedAndroidSpiderError.invalidResponse("缺少可解码 data（operation=\(operation), site=\(site.name)）")
        }
          if case .string(let text) = value,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) {
                return try JSONSerialization.data(withJSONObject: object)
        }
        guard JSONSerialization.isValidJSONObject(value.asAny) else {
            throw ManagedAndroidSpiderError.invalidResponse("data 不是 JSON 对象（operation=\(operation), site=\(site.name)）")
        }
        return try JSONSerialization.data(withJSONObject: value.asAny)
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<binary>"
            throw ManagedAndroidSpiderError.invalidResponse(
                "JSON 解码失败（operation=\(type), bytes=\(data.count)）：\(error.localizedDescription)；响应前缀=\(preview)"
            )
        }
    }

    private func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        } catch {
            throw ManagedAndroidSpiderError.invalidResponse("请求参数编码失败")
        }
    }

    private func decodeCategoryResponse(from data: Data) throws -> CategoryResponse {
            let object = try JSONSerialization.jsonObject(with: data)
            if let root = object as? [String: Any],
               let categories = root["categories"] as? [String] {
                return CategoryResponse(names: categories, ids: Dictionary(uniqueKeysWithValues: categories.map { ($0, $0) }))
            }
            let root = object as? [String: Any] ?? [:]
            let rawClasses = (root["class"] as? [[String: Any]])
                ?? (root["classes"] as? [[String: Any]])
                ?? []
            let pairs = rawClasses.compactMap { item -> (String, String)? in
                let name = (item["type_name"] as? String) ?? (item["name"] as? String)
                let id: String?
                if let value = item["type_id"] as? NSNumber { id = value.stringValue }
                else { id = item["type_id"] as? String }
                guard let name, !name.isEmpty, let id, !id.isEmpty else { return nil }
                return (name, id)
            }
            guard !pairs.isEmpty else {
                throw ManagedAndroidSpiderError.invalidResponse("分类响应缺少 class/type_id/type_name")
            }
        return CategoryResponse(
            names: pairs.map(\.0),
            ids: Dictionary(uniqueKeysWithValues: pairs)
        )
    }
}

private struct CategoryResponse {
    let names: [String]
    let ids: [String: String]
}

private struct BridgePlayResponse: Decodable {
    let url: String
}
