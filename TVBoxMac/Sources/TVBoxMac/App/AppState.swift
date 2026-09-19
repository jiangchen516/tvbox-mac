// AppState.swift — 全局应用状态
import SwiftUI
import TVBoxMacCore

@MainActor
final class AppState: ObservableObject {
    @Published var configs: [ConfigStore.StoredEntry] = []
    @Published var selectedSite: Site?
    @Published var showAllSearch: Bool = false   // 全站搜索模式（侧栏顶部入口）
    @Published var selectedConfig: LoadedConfig?
    @Published var showSettings: Bool = false
    @Published var banner: String?   // 一次性提示（加载 warning 等）

    let client: TVBoxClient
    let configStore = ConfigStore()
    let historyStore = HistoryStore()

    var hasConfig: Bool { !configs.isEmpty }

    var enabledSites: [Site] {
        configs.filter { $0.loaded.enabled }.flatMap { $0.loaded.config.sites }
    }

    init() {
        client = Self.makeClient()
        Task {
            await bootstrap()
        }
    }

    private static func makeClient() -> TVBoxClient {
        guard let bridgeAPK = Bundle.main.url(
                  forResource: "AndroidDexBridge-release",
                  withExtension: "apk"
              ) else {
            return TVBoxClient()
        }

        let sdkRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk", isDirectory: true)
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("TVBoxMac/managed-android-runtime", isDirectory: true)
        let controller = ManagedAndroidRuntimeController(
            sdkRoot: sdkRoot,
            avdName: "TVBoxMac_Runtime",
            avdHome: supportRoot.appendingPathComponent("avd", isDirectory: true),
            userHome: supportRoot.appendingPathComponent("home", isDirectory: true)
        )
        let runtime = ManagedAndroidSpiderRuntime(
            controller: controller,
            bridgeAPK: bridgeAPK
        )
        return TVBoxClient(
            managedAndroidSpider: ManagedAndroidSpiderClient(transport: runtime)
        )
    }

    func bootstrap() async {
        let entries = await configStore.load()
        // 多配置共存：每份配置的 csp_ 站点绑定【该配置自己】解析出的 spider jar。
        // 必须在这里绑定（UI 的站点列表来自 appState.configs）——只在 TVBoxClient
        // 侧绑定的话，UI 传下来的 site 仍是未绑定副本，会回退到全局 spiderURL
        // （第一份配置的 jar），盖掉其他配置的 jar（实测：摸鱼的 qiniu jar 盖掉
        // 饭太硬的 fan.txt → DouDouGuard 等 Guard 站点全空）
        var bound = entries
        for i in bound.indices {
            guard let spiderURL = bound[i].loaded.resolvedGlobalSpiderURL() else { continue }
            for j in bound[i].loaded.config.sites.indices {
                let s = bound[i].loaded.config.sites[j]
                let jarEmpty = s.jar == nil || s.jar?.isEmpty == true
                if jarEmpty && s.api.lowercased().hasPrefix("csp_") {
                    bound[i].loaded.config.sites[j].jar = spiderURL
                }
            }
        }
        configs = bound
        let boundCount = bound.reduce(0) { $0 + $1.loaded.config.sites.filter { $0.jar != nil }.count }
        PlayerLog.append("配置加载: \(bound.count) 份（\(bound.map { $0.loaded.name }.joined(separator: "、"))），已绑定 spider jar 的站点 \(boundCount) 个")
        await client.loadConfigs(bound.map { $0.loaded })
        // 重启后回到上次选中的站点（直接显示其主页/第一个分类页）
        if let last = UserDefaults.standard.string(forKey: Self.lastSiteKey) {
            selectedSite = enabledSites.first { $0.id == last }
        } else {
            selectedSite = nil
        }
    }

    private static let lastSiteKey = "tvboxmac.lastSiteID"

    /// 记录当前选中站点（站点切换时调用）
    func rememberSelectedSite() {
        showAllSearch = false
        if let id = selectedSite?.id {
            UserDefaults.standard.set(id, forKey: Self.lastSiteKey)
        }
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

    /// 全部启用/禁用
    func setAllConfigsEnabled(_ enabled: Bool) async {
        for entry in configs {
            _ = try? await configStore.setEnabled(id: entry.id, enabled: enabled)
        }
        await bootstrap()
    }
}
