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
        // 定位第一个非空白字节，判断顶层类型
        let first = data.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        switch first {
        case UInt8(ascii: "["):
            let sites = try JSONDecoder().decode([Site].self, from: data)
            guard !sites.isEmpty else {
                throw ConfigLoaderError.noSites(sourceDesc)
            }
            return TVBoxConfig(sites: sites)
        case UInt8(ascii: "{"):
            guard let config = try? JSONDecoder().decode(TVBoxConfig.self, from: data) else {
                throw ConfigLoaderError.notJson(sourceDesc)
            }
            guard !config.sites.isEmpty else {
                throw ConfigLoaderError.noSites(sourceDesc)
            }
            return config
        default:
            throw ConfigLoaderError.notJson(sourceDesc)
        }
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
