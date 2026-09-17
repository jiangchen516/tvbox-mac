// ConfigLoader.swift — 加载单配置 / 聚合列表
import Foundation

public enum ConfigLoaderError: LocalizedError {
    case notJson(String)
    case noSites(String)
    case aggregateEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .notJson(let u): return "配置不是合法 JSON: \(u)"
        case .noSites(let u): return "配置缺少 sites 字段: \(u)"
        case .aggregateEmpty(let u): return "聚合列表为空: \(u)"
        }
    }
}

public struct LoadResult: Sendable {
    public var configs: [LoadedConfig]
    public var warnings: [String]
    public init(configs: [LoadedConfig], warnings: [String] = []) {
        self.configs = configs
        self.warnings = warnings
    }
}

public enum ConfigLoader {
    /// 从 JSON 数据解析配置，兼容两种 TVBox 单文件格式：
    /// 1. 完整对象 {"sites":[...], "parses":[...], ...}
    /// 2. 裸站点数组 [{"name","api","type"},...]（单仓/单文件源）
    static func parseConfig(_ data: Data, sourceDesc: String) throws -> TVBoxConfig {
        // 去掉 UTF-8 BOM（部分源文件带 \xEF\xBB\xBF 前缀），再定位第一个非空白字节
        let bytes = Array(data)
        let start = (bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) ? 3 : 0
        let payload = Data(bytes[start...])
        let first = payload.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        switch first {
        case UInt8(ascii: "["):
            let sites = try JSONDecoder().decode([Site].self, from: payload)
            guard !sites.isEmpty else {
                throw ConfigLoaderError.noSites(sourceDesc)
            }
            return TVBoxConfig(sites: sites)
        case UInt8(ascii: "{"):
            guard let config = try? JSONDecoder().decode(TVBoxConfig.self, from: payload) else {
                throw ConfigLoaderError.notJson("\(sourceDesc) —— \(describeResponse(payload))")
            }
            guard !config.sites.isEmpty else {
                throw ConfigLoaderError.noSites(sourceDesc)
            }
            return config
        default:
            // 说人话：告诉用户实际拿到了什么、大概率是什么问题
            throw ConfigLoaderError.notJson("\(sourceDesc) —— \(describeResponse(payload))")
        }
    }

    /// 把"响应不是 JSON"翻译成能直接指导下一步排查的人话
    private static func describeResponse(_ payload: Data) -> String {
        guard !payload.isEmpty else { return "服务器返回了空内容（0 字节），可能地址不对或服务端异常" }
        let compact = String(data: payload.prefix(200), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
            ?? "(无法按文本读取，可能是二进制)"
        let low = compact.lowercased()
        if low.contains("<html") || low.contains("<!doctype html") {
            return "服务器返回的是一个 HTML 网页而不是配置（通常是反爬拦截页，或这个地址不是配置文件）。你可以用浏览器直接打开这个地址对比一下。响应开头: \(compact.prefix(80))"
        }
        if compact.hasPrefix("{") || compact.hasPrefix("[") {
            return "返回的内容看起来是 JSON，但结构不是我们认识的配置格式（应该是 [{站点…}] 数组或 {\"sites\":[…]} 对象）。响应开头: \(compact.prefix(80))"
        }
        return "返回的内容既不是 JSON 也不是可识别的格式。响应开头: \(compact.prefix(80))"
    }

    /// 加载单个配置（完整 JSON 或裸站点数组）
    public static func load(single url: URL, http: HTTPFetching = HttpClient()) async throws -> TVBoxConfig {
        let (data, _) = try await http.get(url, headers: nil)
        return try parseConfig(data, sourceDesc: url.absoluteString)
    }

    /// 加载聚合列表（iyouhun 格式 {"urls":[{name,url}]}），逐条展开；
    /// 单条失败记 warning 跳过，全部失败才抛错。
    public static func load(aggregate url: URL, http: HTTPFetching = HttpClient()) async throws -> LoadResult {
        let (data, _) = try await http.get(url, headers: nil)
        let list = try JSONDecoder().decode(AggregateList.self, from: data)
        guard !list.urls.isEmpty else {
            throw ConfigLoaderError.aggregateEmpty(url.absoluteString)
        }
        var configs: [LoadedConfig] = []
        var warnings: [String] = []
        for entry in list.urls {
            guard let itemURL = URL(string: entry.url) else {
                warnings.append("跳过非法 URL: \(entry.url)")
                continue
            }
            do {
                let config = try await load(single: itemURL, http: http)
                configs.append(LoadedConfig(name: entry.name, url: entry.url, config: config))
            } catch {
                warnings.append("「\(entry.name)」加载失败: \(error.localizedDescription)")
            }
        }
        guard !configs.isEmpty else {
            throw ConfigLoaderError.aggregateEmpty(url.absoluteString)
        }
        return LoadResult(configs: configs, warnings: warnings)
    }

    /// 从本地 JSON 文件加载（设置页"选择文件"用；兼容裸站点数组）
    public static func load(localFile url: URL) throws -> TVBoxConfig {
        let data = try Data(contentsOf: url)
        return try parseConfig(data, sourceDesc: url.lastPathComponent)
    }
}
