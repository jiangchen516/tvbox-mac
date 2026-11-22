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
    // Bridge 返回的播放地址指向安卓侧 loopback（guest:9978 的 FongMi 兼容代理）；
    // 宿主机通过 adb 端口转发（host 19978 → guest 9978）访问，需改写端口
    private let guestProxyPort: Int
    private let hostProxyPort: Int

    public init(transport: any AndroidDexBridgeTransport,
                guestProxyPort: Int = 9978, hostProxyPort: Int = 19978) {
        self.transport = transport
        self.guestProxyPort = guestProxyPort
        self.hostProxyPort = hostProxyPort
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

    public func detail(site: Site, vodId: String) async throws -> Vod {
        // vodId 保留原始形态：豆瓣类 Guard 源是复合字符串（"msearch:###名字###图片@headers"）
        let data = try await call(operation: "detail", site: site,
                                  arguments: ["vodId": .string(vodId)])
        return try decodeDetailVod(from: data, site: site)
    }

    /// detail 响应两种形态：直接 Vod，或 FongMi/CatVod 信封 {"list":[Vod,...]}。
    /// 实测：dex spider 的 detail 返回信封 {"list":[{vod_play_from, vod_play_url, ...}]}，
    /// 直接按 Vod 解码会得到全空字段 → 详情页「未知/空白/无链接」
    /// （实测日志：Bridge← detail OK {"list":[...]} 而 🎬 详情 未知 id=0）
    private func decodeDetailVod(from data: Data, site: Site) throws -> Vod {
        struct DetailEnvelope: Decodable { let list: [Vod]? }
        // 信封优先判断——Vod 宽容解码的默认名是「未知」（非空），不能用名字判空
        if let env = try? decode(DetailEnvelope.self, from: data),
           let first = env.list?.first,
           first.vod_play_url != nil || first.vod_play_from != nil || first.vod_id != 0 {
            return first
        }
        if let vod = try? decode(Vod.self, from: data) {
            return vod
        }
        let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
        throw ManagedAndroidSpiderError.invalidResponse(
            "detail 响应无法映射为 Vod（site=\(site.name)）：\(preview)")
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
        // Bridge 返回的地址指向安卓侧 loopback（guest:9978）；宿主机通过 adb 端口转发
        // （host 19978 → guest 9978）访问——改写为主机侧端口，否则连不上（实测 -1004）
        // parse=1 → jx 解析页（网页 URL，Dm84Guard 类源）——webview 解析出真流
        // （手机端 FongMi 的 parse 子系统做法；webview 加载页面 + JS 捕获真 m3u8）
        if Self.isParseOne(response.parse) {
            PlayerLog.append("🌐 parse=1：jx 页面，走 webview 解析")
            let page = URL(string: response.url)
            if let page {
                let real = try await WebViewParser.shared.resolve(page)
                return real.absoluteString
            }
        }
        // 代理形状（url 指向 bridge 的媒体会话 /proxy/media/<uuid>）：这是桥的
        // 设计路径——writeSessionMedia 直接调 spider 的 proxy()（绕过 play 后即关
        // 的租约）拉流。9979 的 spider 代理 URL 在 play 返回后租约已关（410），不能用
        var hostPlayURL = response.url.replacingOccurrences(
            of: "127.0.0.1:\(guestProxyPort)",
            with: "127.0.0.1:\(hostProxyPort)")
        // FongMi 播放地址可能带 @标记后缀（url@线路名@集数序号）——剥掉，
        // 否则 CDN 看到畸形路径返回 403（手机端 TVBox 会剥）
        if let at = hostPlayURL.firstIndex(of: "@") {
            let candidate = String(hostPlayURL[..<at])
            let low = candidate.lowercased()
            if low.contains(".m3u8") || low.contains(".mp4") {
                PlayerLog.append("▶ 剥 @后缀: \(hostPlayURL.prefix(90)) → \(candidate.prefix(90))")
                hostPlayURL = candidate
            }
        }
        PlayerLog.append("▶ play URL 改写: \(response.url.prefix(80)) → \(hostPlayURL.prefix(80))")
        return hostPlayURL
    }

    /// 从 danmaku 字段提取内层 m3u8 代理 URL：
    /// "http://.../proxy?do=danmu&act=&url=<url编码的 http://.../proxy?do=m3u8&url=...&headers=...>"
    private static func extractProxyM3u8(from danmaku: String) -> String? {
        guard let comps = URLComponents(string: danmaku),
              let outer = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              let inner = URLComponents(string: outer) else { return nil }
        // 内层须是 proxy?do=m3u8 形状
        guard inner.path.contains("/proxy"),
              (inner.queryItems?.first(where: { $0.name == "do" })?.value ?? "").lowercased() == "m3u8"
        else { return nil }
        return outer
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
            // site.spider 是 TVBox 配置允许的站点级实现，优先于配置级全局 jar。
            // 某些配置把多个 Guard 类放在不同 jar 中，不能统一回退到第一份配置的 jar。
            resolvedSite.jar = resolvedSite.spider ?? globalSpiderURL
        }
        // 诊断日志：Bridge 请求（含 ext 预览——ext 是 Guard 源最常见的失败原因）
        let extPreview: String
        if case .string(let s)? = resolvedSite.ext { extPreview = String(s.prefix(120)) }
        else if case .object(let d)? = resolvedSite.ext {
            // d 是 [String: JSONValue]（原始枚举）——直接给 NSJSONSerialization 会抛
            // ObjC 异常（_writeJSONValue，Swift try? 接不住 → 启动即崩，实测）。
            // 必须先转成 JSON 安全类型（.asAny）再序列化
            let safe = d.mapValues { $0.asAny }
            let json = (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            extPreview = String(json.prefix(120))
        } else { extPreview = "-" }
        PlayerLog.append("Bridge→ \(operation) site=\(site.name) api=\(site.api) jar=\((resolvedSite.jar ?? "-").prefix(90)) ext=\(extPreview)")
        let request = AndroidDexBridgeRequest(operation: operation, site: resolvedSite, arguments: arguments)
        let response: AndroidDexBridgeResponse
        do {
            response = try await transport.send(request)
        } catch {
            PlayerLog.append("Bridge← \(operation) 传输失败: \(error.localizedDescription)")
            throw ManagedAndroidSpiderError.bridge(error.localizedDescription)
        }
        guard response.ok else {
            PlayerLog.append("Bridge← \(operation) ok=false error=\(response.error ?? "未知错误")")
            throw ManagedAndroidSpiderError.bridge(response.error ?? "未知错误")
        }
        guard let value = response.data else {
            PlayerLog.append("Bridge← \(operation) 缺少 data")
            throw ManagedAndroidSpiderError.invalidResponse("缺少可解码 data（operation=\(operation), site=\(site.name)）")
        }
        // 归一化 + 记录响应预览（raw dex spider 返回的字段名可能是任意形状）
        var current = value
        let jarDescription = site.jar ?? globalSpiderURL ?? ""
        for _ in 0..<3 {
            if case .string(let text) = current,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 空串 = spider 正常返回但没有数据。对 csp_ 站点，最常见原因是
                // 配置的 spider jar 里没有这个 api 类（jar 版本与源不匹配/失效），
                // 或该源需要 ext 而站点未提供——给用户有指导性的错误
                // search/browse 的空结果只是"没搜到/没数据"，不该提示 jar 不匹配；
                // categories/detail 空了才是 jar 缺类/失效的信号
                let hint: String
                if operation == "search" || operation == "browse" {
                    hint = "没有找到结果（无匹配或源已失效）"
                } else if site.api.lowercased().hasPrefix("csp_") {
                    hint = "该源的 spider jar 里可能没有 \(site.api) 类（jar 版本不匹配或已失效），或此源需要 ext 配置。请换线路/换配置试试"
                } else {
                    hint = "源返回了空数据（可能已失效）"
                }
                PlayerLog.append("Bridge← \(operation) 空数据 jar=\(jarDescription.prefix(90)) ext=\(extPreview)")
                throw ManagedAndroidSpiderError.invalidResponse(
                    "Bridge 返回空数据：\(hint)（operation=\(operation), site=\(site.name), api=\(site.api), jar=\(jarDescription.prefix(80))）"
                )
            }
            if case .string(let text) = current,
               let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                PlayerLog.append("Bridge← \(operation) 字符串响应(\(text.count)B) 前 400: \(String(text.prefix(400)))")
                current = Self.jsonValue(from: object)
                continue
            }
            break
        }
        guard JSONSerialization.isValidJSONObject(current.asAny) else {
            PlayerLog.append("Bridge← \(operation) 非 JSON: \(String(describing: current).prefix(400))")
            throw ManagedAndroidSpiderError.invalidResponse(
                "data 不是 JSON 容器（operation=\(operation), site=\(site.name), api=\(site.api), jar=\(jarDescription), value=\(String(describing: current).prefix(400))）"
            )
        }
        let out = try JSONSerialization.data(withJSONObject: current.asAny)
        PlayerLog.append("Bridge← \(operation) OK(\(out.count)B) 前 300: \(String(data: out.prefix(300), encoding: .utf8) ?? "")")
        return out
    }
    /// parse 标志：实测有数字 1 和字符串 "1" 两种形态
    private static func isParseOne(_ v: JSONValue?) -> Bool {
        switch v {
        case .number(let n): return n == 1
        case .string(let s): return s == "1"
        default: return false
        }
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
                // class 键在但数组为空 = spider 跑通、源站没给数据（实测 dm84 宕机返回 {"class":[],"list":[]}）
                if rawClasses.isEmpty && (root["class"] != nil || root["classes"] != nil) {
                    throw ManagedAndroidSpiderError.invalidResponse(
                        "源站当前无响应或已失效（spider 返回空分类），请稍后重试或换源")
                }
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
    // spider 代理 URL（9979 /proxy?do=m3u8&url=...&headers=...）——
    // spider 的 proxy 服务带请求头拉流，手机端 FongMi 就是用它
    let danmaku: String?
    // parse=1 → 返回的是 jx 解析页（网页 URL），需要 webview 解析真流
    let parse: JSONValue?
}
