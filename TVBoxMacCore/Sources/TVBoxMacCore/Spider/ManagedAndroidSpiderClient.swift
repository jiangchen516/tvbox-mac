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
    private var categoryNames: [String: [String]] = [:]

    public init(transport: any AndroidDexBridgeTransport) {
        self.transport = transport
    }

    public func setGlobalSpiderURL(_ url: String?) {
        globalSpiderURL = url
    }

    public func categories(site: Site) async throws -> [String] {
        if let names = categoryNames[site.id] {
            return names
        }
        let data = try await call(operation: "categories", site: site)
        let response = try decodeCategoryResponse(from: data)
        categoryIDs[site.id] = response.ids
        categoryNames[site.id] = response.names
        return response.names
    }

    public func browse(site: Site, category: String?, page: Int) async throws -> VodPage {
                _ = try await categories(site: site)
                let displayCategory = category ?? ""
                let resolvedCategory = categoryIDs[site.id]?[displayCategory] ?? displayCategory
                do {
                    let result = try await browse(site: site, categoryValue: resolvedCategory, page: page, filter: false)
                    if result.list.isEmpty {
                        await resetSpider(site: site)
                        _ = try? await categories(site: site)
                        let retry = try await browse(site: site, categoryValue: resolvedCategory, page: page, filter: false)
                        return retry.list.isEmpty
                            ? try await browse(site: site, categoryValue: resolvedCategory, page: page, filter: true)
                            : retry
                    }
                    return result
                } catch let error as ManagedAndroidSpiderError
                                        where displayCategory != resolvedCategory
                                        && error.localizedDescription.localizedCaseInsensitiveContains("category invalid") {
                        // Some legacy spiders expose names instead of numeric type IDs.
                        return try await browse(site: site, categoryValue: displayCategory, page: page, filter: false)
                }
    }

                private func browse(site: Site, categoryValue: String, page: Int, filter: Bool) async throws -> VodPage {
                let data = try await call(operation: "browse", site: site, arguments: [
                        "category": .string(categoryValue),
                        "page": .number(Double(page)),
                        "filter": .bool(filter)
                ])
                return try decodeSpiderPage(from: data, page: page, operation: "browse")
        }

    public func search(site: Site, keyword: String, page: Int) async throws -> VodPage {
                let data = try await call(operation: "search", site: site, arguments: [
                        "keyword": .string(keyword),
                        "page": .number(Double(page))
                ])
                return try decodeSpiderPage(from: data, page: page, operation: "search")
    }

    private func resetSpider(site: Site) async {
        _ = try? await call(operation: "destroy", site: site)
        categoryIDs[site.id] = nil
        categoryNames[site.id] = nil
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
        var current = value
        let jarDescription = site.jar ?? globalSpiderURL ?? ""
        for _ in 0..<3 {
            if case .string(let text) = current,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 空串 = spider 正常返回但没有数据。对 csp_ 站点，最常见原因是
                // 配置的 spider jar 里没有这个 api 类（jar 版本与源不匹配/失效），
                // 或该源需要 ext 而站点未提供——给用户有指导性的错误而不是裸"空字符串"
                let hint = site.api.lowercased().hasPrefix("csp_")
                    ? "该源的 spider jar 里可能没有 \(site.api) 类（jar 版本不匹配或已失效），或此源需要 ext 配置。请换线路/换配置试试"
                    : "源返回了空数据（可能已失效）"
                throw ManagedAndroidSpiderError.invalidResponse(
                    "Bridge 返回空数据：\(hint)（operation=\(operation), site=\(site.name), api=\(site.api), jar=\(jarDescription.prefix(80))）"
                )
            }
            if case .string(let text) = current,
               let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                current = Self.jsonValue(from: object)
                continue
            }
            break
        }
        guard JSONSerialization.isValidJSONObject(current.asAny) else {
            throw ManagedAndroidSpiderError.invalidResponse(
                "data 不是 JSON 容器（operation=\(operation), site=\(site.name), api=\(site.api), jar=\(jarDescription), value=\(current)）"
            )
        }
        return try JSONSerialization.data(withJSONObject: current.asAny)
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

    private func decodeSpiderPage(from data: Data, page: Int, operation: String) throws -> VodPage {
        if let page = try? decode(VodPage.self, from: data) {
            return page
        }
        struct SpiderEnvelope: Decodable {
            let list: [Vod]?
            let page: Int?
            let pagecount: Int?
            let total: Int?
        }
        do {
            let envelope = try JSONDecoder().decode(SpiderEnvelope.self, from: data)
            let list = envelope.list ?? []
            return VodPage(
                page: envelope.page ?? page,
                pagecount: envelope.pagecount ?? (list.isEmpty ? page : page + 1),
                limit: 20,
                total: envelope.total ?? list.count,
                list: list
            )
        } catch {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<binary>"
            throw ManagedAndroidSpiderError.invalidResponse(
                "Spider \(operation) 响应无法映射为列表（bytes=\(data.count)）：\(error.localizedDescription)；响应前缀=\(preview)"
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

    private static func jsonValue(from value: Any) -> JSONValue {
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        }
        if let value = value as? [Any] { return .array(value.map(jsonValue(from:))) }
        if let value = value as? [String: Any] {
            return .object(value.mapValues(jsonValue(from:)))
        }
        return .null
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
