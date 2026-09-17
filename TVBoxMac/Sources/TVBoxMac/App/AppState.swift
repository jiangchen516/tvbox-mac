// AppState.swift — 全局应用状态
import SwiftUI
import TVBoxMacCore

@MainActor
final class AppState: ObservableObject {
    @Published var configs: [ConfigStore.StoredEntry] = []
    @Published var selectedSite: Site?
    @Published var selectedConfig: LoadedConfig?
    @Published var showSettings: Bool = false
    @Published var banner: String?   // 一次性提示（加载 warning 等）

    let client = TVBoxClient()
    let configStore = ConfigStore()
    let historyStore = HistoryStore()

    var hasConfig: Bool { !configs.isEmpty }

    var enabledSites: [Site] {
        configs.filter { $0.loaded.enabled }.flatMap { $0.loaded.config.sites }
    }

    init() {
        Task {
            await bootstrap()
        }
    }

    func bootstrap() async {
        let entries = await configStore.load()
        configs = entries
        await client.loadConfigs(entries.map { $0.loaded })
        selectedSite = nil
    }

    /// 导入配置（URL，可能是单配置或聚合列表；按响应内容自动判断）
    func importConfig(from url: URL) async {
        let http = HttpClient()
        do {
            let (data, _) = try await http.get(url, headers: nil)
            let text = String(data: data, encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAggregate = trimmed.hasPrefix("{") && trimmed.contains("\"urls\"")
                && !trimmed.contains("\"sites\"")
            if isAggregate {
                let result = try await ConfigLoader.load(aggregate: url, http: http)
                for cfg in result.configs {
                    _ = try await configStore.add(cfg)
                }
                if !result.warnings.isEmpty {
                    banner = "部分源加载失败:\n" + result.warnings.joined(separator: "\n")
                }
            } else {
                let config = try await ConfigLoader.load(single: url, http: http)
                let name = config.sites.first?.name ?? url.lastPathComponent
                _ = try await configStore.add(LoadedConfig(name: name, url: url.absoluteString, config: config))
            }
            await bootstrap()
        } catch {
            banner = "导入失败: \(error.localizedDescription)"
        }
    }

    /// 导入本地 JSON 文件
    func importConfig(fromFile url: URL) async {
        do {
            let config = try ConfigLoader.load(localFile: url)
            let name = config.sites.first?.name ?? url.lastPathComponent
            _ = try await configStore.add(LoadedConfig(name: name, url: "local:\(url.lastPathComponent)", config: config))
            await bootstrap()
        } catch {
            banner = "导入失败: \(error.localizedDescription)"
        }
    }

    func removeConfig(id: String) async {
        _ = try? await configStore.remove(id: id)
        if selectedSite == nil || enabledSites.allSatisfy({ $0.id != selectedSite?.id }) {
            selectedSite = nil
        }
        await bootstrap()
    }

    func setConfigEnabled(id: String, enabled: Bool) async {
        _ = try? await configStore.setEnabled(id: id, enabled: enabled)
        await bootstrap()
    }
}
