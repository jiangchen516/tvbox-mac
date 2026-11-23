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
    // 模拟器内部 DNS/网络失效时，所有 jar 源会同时返回空响应。
    // 连续识别到网络类错误后自动重启一次运行时（10 分钟冷却）。
    private var networkFailureStreak = 0
    private var lastNetworkFailureAt = Date.distantPast
    private var lastRuntimeRestartAt = Date.distantPast
    private var runtimeRestartPending = false
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
        do {
            let data = try await call(operation: "search", site: site, arguments: [
                "keyword": .string(keyword),
                "page": .number(Double(page))
            ])
            let result = try decodeSpiderPage(from: data, page: page, operation: "search")
            guard result.list.isEmpty else { return result }
            // 三参搜索空结果时，部分 spider 只实现了两参 searchContent；
            // 再用两参重试一次（真正的空结果只会多一次快速调用）。
            return try await searchTwoArgumentFallback(site: site, keyword: keyword, page: page) ?? result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let fallback = try? await searchTwoArgumentFallback(site: site, keyword: keyword, page: page),
               !fallback.list.isEmpty {
                return fallback
            }
            // 两参也空：这是“没搜到”，不是站点加载失败，返回空列表而不是抛错。
            if case ManagedAndroidSpiderError.invalidResponse(let message) = error,
               message.contains("Bridge 返回空数据") {
                return VodPage(page: page, pagecount: page, limit: 0, total: 0, list: [])
            }
            throw error
        }
    }

    private func searchTwoArgumentFallback(site: Site, keyword: String, page: Int) async throws -> VodPage? {
        let data = try await call(operation: "search", site: site, arguments: [
            "keyword": .string(keyword),
            "page": .number(Double(page)),
            "__searchTwoArg": .bool(true)
        ])
        return try decodeSpiderPage(from: data, page: page, operation: "search")
    }

    /// 判断是否为“模拟器网络/DNS 失效”类错误；连续 3 次触发一次自动重启。
    private func noteNetworkFailure(_ message: String) {
        let signatures = [
            "UnknownHostException", "EAI_NODATA", "Unable to resolve host",
            "End of input at character 0", "Network is unreachable",
            "Connection refused", "connect timed out", "SocketTimeout"
        ]
        guard signatures.contains(where: { message.localizedCaseInsensitiveContains($0) }) else { return }
        let now = Date()
        if now.timeIntervalSince(lastNetworkFailureAt) < 120 {
            networkFailureStreak += 1
        } else {
            networkFailureStreak = 1
        }
        lastNetworkFailureAt = now
        guard networkFailureStreak >= 3,
              now.timeIntervalSince(lastRuntimeRestartAt) > 600 else { return }
        networkFailureStreak = 0
        runtimeRestartPending = true
        PlayerLog.append("⚠️ 连续 3 次模拟器网络类失败，下一次请求前将重启运行时")
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

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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
        if runtimeRestartPending {
            runtimeRestartPending = false
            lastRuntimeRestartAt = Date()
            PlayerLog.append("♻️ 检测到模拟器网络持续异常，自动重启 Android 运行时…")
            do {
                try await transport.restart()
                PlayerLog.append("♻️ Android 运行时已重启（DNS/网络恢复）")
            } catch {
                PlayerLog.append("♻️ Android 运行时重启失败: \(error.localizedDescription)")
            }
        }
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
            if Self.isCancellation(error) {
                // 切换站点/分类时 SwiftUI 会取消旧任务，这是正常导航行为，
                // 不要包装成 Bridge 失败，否则页面会弹错误提示。
                PlayerLog.append("Bridge← \(operation) 已取消（页面切换或请求替换）")
                throw CancellationError()
            }
            PlayerLog.append("Bridge← \(operation) 传输失败: \(error.localizedDescription)")
            noteNetworkFailure(error.localizedDescription)
            throw ManagedAndroidSpiderError.bridge(error.localizedDescription)
        }
        guard response.ok else {
            let message = response.error ?? "未知错误"
            PlayerLog.append("Bridge← \(operation) ok=false error=\(message)")
            noteNetworkFailure(message)
            throw ManagedAndroidSpiderError.bridge(message)
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
                } else if operation == "play" {
                    hint = "播放接口没有返回地址（可能是该歌曲/线路失效，或当前 Spider 版本与源不兼容）"
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

    private func decodeSpiderPage(from data: Data, page requestedPage: Int, operation: String) throws -> VodPage {
        do {
            // Guard Spider（糯米等）常把 page/pagecount/total 编成字符串，
            // 而 CatVod 则常用数字。先解成 JSONValue，再逐项宽容转换，避免
            // page="1" 令整个 VodPage/合成 envelope 解码失败。
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let root) = value else {
                throw ManagedAndroidSpiderError.invalidResponse("响应根节点不是 JSON 对象")
            }
            let rawList = LenientJSON.valueArray(root["list"])
            let list = try rawList.map { item -> Vod in
                let itemData = try JSONEncoder().encode(item)
                return try JSONDecoder().decode(Vod.self, from: itemData)
            }
            let resolvedPage = LenientJSON.int(root["page"]) ?? requestedPage
            let pageCount = LenientJSON.int(root["pagecount"])
                ?? (list.isEmpty ? resolvedPage : resolvedPage + 1)
            return VodPage(
                page: resolvedPage,
                pagecount: pageCount,
                limit: LenientJSON.int(root["limit"]) ?? 20,
                total: LenientJSON.int(root["total"]) ?? list.count,
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
